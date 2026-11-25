#!/usr/bin/env bash
# shellcheck disable=SC2015  # "write_file ... && flag=1 || true" is intended: 1 means unchanged.
#
# install.sh — set up a Raspberry Pi as an RC Race HQ lap counter.
#
#   curl -fsSL https://www.rcracehq.com/lapcounter/install.sh | sudo bash
#
# Plain bash, no Ansible. What it does:
#
#   1. Checks      arm64 Pi, Raspberry Pi OS Trixie (Debian 13+) or Ubuntu 24.04+,
#                  run with sudo by a normal user, wired network up, apt not
#                  busy with automatic updates (fails fast instead of waiting)
#   2. Packages    curl, jq, python3, nftables, ...
#   3. Decoder     OpenStint (upstream .deb, or built from a pinned commit on
#                  Ubuntu), /etc/openstint.conf, openstint-learn, USB access
#   4. Event Wi-Fi wlan0 access point "RC Race Event", DHCP/DNS, captive portal
#                  at http://race/  (skip with --no-ap)
#   5. Docker      Docker Engine + compose plugin from Docker's signed repo
#   6. App         lapd + web + syncd containers, pinned to one image build
#   7. Screen      status screen on the console (skip with --no-screen), and
#                  a small SPI LCD's driver with --lcd
#   8. Check       portal on :80, app behind it (Pi-only :8080), decoder running
#
# Safe to run again: re-running is also how you update or change options.
#
# Options (all optional):
#   [TAG]                Image build to install: latest (default), sha-1a2b3c4,
#                        1a2b3c4 or v1.2.3. "latest" is resolved to its exact
#                        build, and the Pi stays on that build until you re-run.
#   --tag TAG            Same as the positional TAG.
#   --no-ap              Don't turn wlan0 into the event Wi-Fi. The app is still
#                        served on the wired side at http://<hostname>.local/.
#   --hostname NAME      Rename the Pi (also its .local name).
#   --ssid NAME          Event Wi-Fi name          (default: RC Race Event)
#   --passphrase PASS    Event Wi-Fi password, 8-63 characters (default: open)
#   --country CC         Wi-Fi country code         (default: US)
#   --no-screen          Don't put the status screen on the console (tty1).
#                        Normally tty1 shows the wired IP, the event Wi-Fi, the
#                        race on track and any problems (SDR unplugged, ...).
#   --lcd MODEL          Set up a small SPI LCD on the GPIO header. Models:
#                          waveshare35a  Waveshare / SpotPear 3.5" RPi LCD (A),
#                                        incl. V3 (ILI9486 + XPT2046 touch)
#                          none          remove an LCD set up earlier
#                        Leave it off to keep whatever is set up now. Needs a
#                        reboot the first time.
#   --lcd-rotate DEG     LCD rotation: 0, 90, 180 or 270 (default: 270)
#   -h, --help           Show this help.
#
# Pass options through the pipe with "bash -s --":
#   curl -fsSL .../install.sh | sudo bash -s -- --no-ap sha-1a2b3c4
#
# Environment (optional):
#   INSTALL_REF          Branch/tag/commit of this repo to fetch helper files
#                        from (main; the rcracehq.com copy is pinned to its commit)
#   GHCR_USER/GHCR_TOKEN Registry login, only for a private image
#
# Full log: /var/log/lapcounter-install.log
#
# SPDX-License-Identifier: LicenseRef-FSL-1.1-ALv2
# Copyright 2026 Sturgeon Technologies LLC

set -Eeuo pipefail

# ════════════════════════════════════════════════════════════════════════════
#  Settings
# ════════════════════════════════════════════════════════════════════════════

# ── Image ────────────────────────────────────────────────────────────────────
readonly REGISTRY="ghcr.io"
readonly IMAGE_PATH="sturgeontechnologies/rcracehq-lapcounter"
readonly IMAGE_REPO="${REGISTRY}/${IMAGE_PATH}"

# ── Where helper files (portal, openstint-learn) come from ───────────────────
readonly INSTALL_REPO="SturgeonTechnologies/RCRaceHQ-LapCounter-Install"
INSTALL_REF="${INSTALL_REF:-main}"

# ── OpenStint decoder ────────────────────────────────────────────────────────
readonly OPENSTINT_APT_URL="https://repo.lapbeeps.com/apt/"
readonly OPENSTINT_APT_ORIGIN="repo.lapbeeps.com"
readonly OPENSTINT_SRC_REPO="https://github.com/zsellera/openstint.git"
readonly OPENSTINT_SRC_COMMIT="d60982a6cb09c3456ad29b29b24c2b21a9820522"
readonly OPENSTINT_BUILD_USER="openstint-build"
readonly OPENSTINT_BUILD_DIR="/var/cache/openstint-build"
readonly OPENSTINT_GAIN=20
readonly OPENSTINT_ZMQ_PORT=5556
readonly RC4_DIR="/var/lib/openstint"
readonly NFPM_VERSION="2.43.0"
readonly NFPM_SHA256_ARM64="2529b6b3fbd107b57064158a183de6a9801f78d5232980cf46419564491fa5c2"

# ── Docker ───────────────────────────────────────────────────────────────────
readonly DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

# ── App ──────────────────────────────────────────────────────────────────────
readonly APP_DIR="/opt/lapcounter"
readonly APP_DATA_DIR="/var/lib/lapcounter"
readonly APP_UID=10001
readonly APP_PORT=8080
readonly RCRACEHQ_API_URL="https://www.rcracehq.com/api"

# ── Event Wi-Fi ──────────────────────────────────────────────────────────────
readonly WIFI_IF="wlan0"
readonly WIRED_IF="eth0"
readonly AP_ADDRESS="10.77.0.1"
readonly AP_PREFIX=24
readonly AP_NETMASK="255.255.255.0"
readonly AP_DHCP_START="10.77.0.50"
readonly AP_DHCP_END="10.77.0.250"
readonly AP_HOSTNAME="race"
readonly AP_DOMAIN="lan"
readonly PORTAL_PORT=80

# ── Small SPI LCD (--lcd) ────────────────────────────────────────────────────
# Overlay files are downloaded from a pinned commit and checked by sha256.
# Raspberry Pi dropped waveshare35a from its firmware, and Ubuntu never had it.
readonly LCD_SHARE_DIR="/usr/local/share/lapcounter-lcd"
readonly LCD_HOOK_NAME="zzz-lapcounter-lcd"
readonly LCD_BEGIN="# >>> RC Race HQ lap counter LCD (install.sh manages this block) >>>"
readonly LCD_END="# <<< RC Race HQ lap counter LCD <<<"
readonly LCD_WAIT_S=30

# lcd_profile MODEL: sets LCD_OVERLAY, LCD_URL, LCD_SHA256. Add screens here.
lcd_profile() {
    case $1 in
        waveshare35a)
            LCD_OVERLAY=waveshare35a
            LCD_URL="https://raw.githubusercontent.com/waveshare/LCD-show/baba588993fcec7abaaf0b2167303086d42f1057/waveshare35a-overlay.dtb"
            LCD_SHA256="4e879f464dd97387282e68de9ab66b9cc85627fb0b02618ca44cc0a94644ee7d"
            ;;
        *) return 1 ;;
    esac
}
readonly LCD_MODELS="waveshare35a"

# ── Defaults for the options ─────────────────────────────────────────────────
TAG="latest"
WITH_AP=1
WITH_SCREEN=1
NEW_HOSTNAME=""
AP_SSID="RC Race Event"
AP_PASSPHRASE=""
AP_COUNTRY="US"

LCD_MODEL=""          # "" = leave as is, none = remove, else a model below
LCD_ROTATE=270

readonly LOG_FILE="/var/log/lapcounter-install.log"
readonly STATE_FILE="/etc/lapcounter-install.conf"

# ════════════════════════════════════════════════════════════════════════════
#  Helpers
# ════════════════════════════════════════════════════════════════════════════

if [[ -t 1 ]]; then
    C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_OFF=$'\e[0m'
else
    C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi

STEP=0
step() { STEP=$((STEP + 1)); printf '\n%s== %d. %s ==%s\n' "$C_BOLD" "$STEP" "$*" "$C_OFF"; }
info() { printf '   %s\n' "$*"; }
ok()   { printf '   %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '   %s!%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '\n%s✗ %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }

on_error() {
    printf '\n%s✗ Failed at line %s: %s%s\n' "$C_RED" "$1" "$2" "$C_OFF" >&2
    printf '  Full log: %s\n  Fix the problem and run the installer again; it picks up where it left off.\n' \
        "$LOG_FILE" >&2
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

usage() { sed -n '4,/^# SPDX/{/^# SPDX/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}" 2>/dev/null \
    || echo "See the header of install.sh in ${INSTALL_REPO}"; }

# apt-get without questions; quiet unless it fails.
#   check_apt has already made sure apt was free and paused the automatic
#   updates, so a lock that is still held after 2 minutes means something is
#   wrong; fail rather than sit silently. Network timeouts stop a dead mirror
#   from hanging the install, and NEEDRESTART_MODE stops Ubuntu's "restart
#   services?" dialog.
APT_OPTS=(-q -o DPkg::Lock::Timeout=120 -o Acquire::http::Timeout=30
          -o Acquire::https::Timeout=30 -o Acquire::Retries=3)
apt_get() { DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "${APT_OPTS[@]}" "$@"; }

apt_install() {
    apt_get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" >/dev/null
}

APT_UPDATED=0
apt_update() {
    if [[ $APT_UPDATED -eq 0 ]]; then
        apt_get update >/dev/null
        APT_UPDATED=1
    fi
}

is_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

# Write a file only when its content changed. Returns 0 = changed, 1 = same.
#   write_file PATH MODE <<'EOF' ... EOF
write_file() {
    local path=$1 mode=$2 tmp
    tmp=$(mktemp)
    cat >"$tmp"
    if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
    install -D -o root -g root -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
    return 0
}

# Fetch a helper file from this repo: the local copy when run from a clone,
# otherwise from GitHub at INSTALL_REF.
SCRIPT_DIR=""
if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]]; then
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi
fetch_repo_file() {
    local rel=$1 dest=$2
    if [[ -n $SCRIPT_DIR && -f $SCRIPT_DIR/$rel ]]; then
        cp "$SCRIPT_DIR/$rel" "$dest"
    else
        curl -fsSL --retry 3 "https://raw.githubusercontent.com/${INSTALL_REPO}/${INSTALL_REF}/${rel}" -o "$dest"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
#  Options
# ════════════════════════════════════════════════════════════════════════════

parse_args() {
    local tag_set=0
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)     usage; exit 0 ;;
            --no-ap)       WITH_AP=0 ;;
            --no-screen)   WITH_SCREEN=0 ;;
            --tag)         TAG=${2:?--tag needs a value}; tag_set=1; shift ;;
            --hostname)    NEW_HOSTNAME=${2:?--hostname needs a value}; shift ;;
            --ssid)        AP_SSID=${2:?--ssid needs a value}; shift ;;
            --passphrase)  AP_PASSPHRASE=${2:?--passphrase needs a value}; shift ;;
            --country)     AP_COUNTRY=${2:?--country needs a value}; shift ;;
            --lcd)         LCD_MODEL=${2:?--lcd needs a model (see --help)}; shift ;;
            --lcd-rotate)  LCD_ROTATE=${2:?--lcd-rotate needs 0, 90, 180 or 270}; shift ;;
            -*)            die "Unknown option: $1 (see --help)" ;;
            *)
                [[ $tag_set -eq 0 ]] || die "Only one image tag, please (got '$TAG' and '$1')"
                TAG=$1; tag_set=1 ;;
        esac
        shift
    done

    # A bare commit (1a2b3c4 or the full 40 characters) means sha-<first 7>.
    if [[ $TAG =~ ^[0-9a-f]{7,40}$ ]]; then
        TAG="sha-${TAG:0:7}"
    fi
    [[ $TAG == latest || $TAG =~ ^sha-[0-9a-f]{7}$ || $TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
        || die "Image tag '$TAG' isn't latest, sha-<7 hex>, <7+ hex> or vX.Y.Z"

    [[ -z $NEW_HOSTNAME || $NEW_HOSTNAME =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
        || die "--hostname must be lowercase letters, digits and dashes (1-63, no dash at either end)"
    [[ $AP_COUNTRY =~ ^[A-Z]{2}$ ]] || die "--country must be a 2-letter code like US"
    [[ -z $AP_PASSPHRASE || ( ${#AP_PASSPHRASE} -ge 8 && ${#AP_PASSPHRASE} -le 63 ) ]] \
        || die "--passphrase must be 8-63 characters (or leave it off for an open network)"
    [[ ${#AP_SSID} -ge 1 && ${#AP_SSID} -le 32 ]] || die "--ssid must be 1-32 characters"
    [[ -z $LCD_MODEL || $LCD_MODEL == none ]] || lcd_profile "$LCD_MODEL" \
        || die "--lcd '$LCD_MODEL' isn't a known screen. Known: $LCD_MODELS (or none)"
    [[ $LCD_ROTATE =~ ^(0|90|180|270)$ ]] || die "--lcd-rotate must be 0, 90, 180 or 270"
}

# ════════════════════════════════════════════════════════════════════════════
#  1. Checks
# ════════════════════════════════════════════════════════════════════════════

OS_ID=""; OS_VERSION=""; OS_CODENAME=""; TARGET_USER=""; OPENSTINT_METHOD=""

check_user() {
    # Needs root for apt/systemd, but also the real login user (for the
    # transponder folder's group). So: a normal user running it with sudo.
    if [[ $EUID -ne 0 ]]; then
        die "Run it with sudo as your normal user:  curl -fsSL <url> | sudo bash"
    fi
    TARGET_USER=${SUDO_USER:-}
    if [[ -z $TARGET_USER || $TARGET_USER == root ]]; then
        die "Run this as your normal (sudo) user with sudo, not as root directly."
    fi
    if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel'; then
        die "$TARGET_USER isn't in the sudo group. Use the account you set up when imaging the Pi."
    fi
    ok "Running as $TARGET_USER with sudo"
}

check_platform() {
    [[ $(uname -m) == aarch64 ]] \
        || die "This needs a 64-bit (arm64) OS. This one is $(uname -m). Re-image with the 64-bit version."

    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID=${ID:-}
    OS_VERSION=${VERSION_ID:-0}
    OS_CODENAME=${VERSION_CODENAME:-}

    case $OS_ID in
        debian|raspbian)
            [[ ${OS_VERSION%%.*} -ge 13 ]] \
                || die "Raspberry Pi OS / Debian $OS_VERSION is too old. Use Raspberry Pi OS Trixie (Debian 13) or newer."
            OS_ID=debian
            OPENSTINT_METHOD=apt
            ;;
        ubuntu)
            [[ $(printf '%s\n' 24.04 "$OS_VERSION" | sort -V | head -1) == 24.04 ]] \
                || die "Ubuntu $OS_VERSION is too old. Use Ubuntu 24.04 or newer."
            OPENSTINT_METHOD=source
            ;;
        *)
            die "Unsupported OS '${PRETTY_NAME:-$OS_ID}'. Use Raspberry Pi OS Trixie or Ubuntu 24.04+ (arm64)."
            ;;
    esac
    ok "${PRETTY_NAME:-$OS_ID $OS_VERSION} on arm64"

    local model=""
    [[ -r /proc/device-tree/model ]] && model=$(tr -d '\0' </proc/device-tree/model)
    if [[ -n $model ]]; then
        if [[ $model =~ Raspberry\ Pi\ (1|2|Zero|3\ Model\ B\ Rev) ]]; then
            warn "$model is below OpenStint's minimum (Pi 3 Model B+); it may drop samples."
        else
            ok "$model"
        fi
    fi
}

check_network() {
    ip link show "$WIRED_IF" >/dev/null 2>&1 \
        || die "No $WIRED_IF port found. The lap counter uses the wired port for its internet."

    local route_if
    route_if=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    if [[ $WITH_AP -eq 1 && $route_if == "$WIFI_IF" ]]; then
        die "This Pi gets its internet over $WIFI_IF, which is about to become the event Wi-Fi.
  Plug in Ethernet and run again, or use --no-ap."
    fi
    [[ $route_if == "$WIRED_IF" ]] || warn "Default route is on '${route_if:-nothing}', not $WIRED_IF."

    # Any HTTP answer (ghcr.io says 401 without a token) means we're online.
    curl -sS -m 10 -o /dev/null https://ghcr.io/v2/ 2>/dev/null \
        || die "Can't reach ghcr.io. Check the Pi's internet connection."
    ok "Internet over ${route_if:-?}"
}

# Fail fast when apt is busy or broken, instead of waiting behind it.
# A freshly imaged Pi usually runs its first automatic upgrade within minutes
# of booting, and that can hold apt for a long time.
readonly APT_LOCKS=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
                    /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
readonly APT_TIMERS=(apt-daily.timer apt-daily-upgrade.timer)
APT_TIMERS_PAUSED=()

# "PID command" for every process holding an apt/dpkg lock (from /proc/locks).
apt_lock_holders() {
    local f inode pid
    local -A seen=()
    for f in "${APT_LOCKS[@]}"; do
        [[ -e $f ]] || continue
        inode=$(stat -c %i "$f")
        while read -r pid; do
            [[ $pid =~ ^[0-9]+$ && -z ${seen[$pid]:-} ]] || continue
            seen[$pid]=1
            ps -o pid=,args= -p "$pid" 2>/dev/null | cut -c1-100 || true
        done < <(awk -v ino="$inode" '$2 != "->" { n = split($6, d, ":"); if (d[n] == ino) print $5 }' /proc/locks)
    done
}

check_apt() {
    local holders running=() unit
    holders=$(apt_lock_holders)
    for unit in apt-daily.service apt-daily-upgrade.service; do
        systemctl is-active --quiet "$unit" 2>/dev/null && running+=("$unit")
    done
    if [[ -n $holders || ${#running[@]} -gt 0 ]]; then
        local busy=""
        local line
        while read -r line; do
            [[ -n $line ]] && busy+="    ${line}"$'\n'
        done <<<"$holders"
        [[ ${#running[@]} -gt 0 ]] && busy+="    running: ${running[*]}"$'\n'
        die "apt is busy, most likely with automatic updates (normal on a freshly imaged Pi).
${busy}  Either wait for it to finish (usually 5-15 minutes) and run this again, or stop it now:
    sudo systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service
  and run this again."
    fi

    if [[ -n $(dpkg --audit 2>/dev/null) || -n $(ls -A /var/lib/dpkg/updates 2>/dev/null) ]]; then
        die "An earlier package install was interrupted, so apt can't install anything.
  Fix it with:  sudo dpkg --configure -a
  then run this again."
    fi

    # Keep the automatic updates from starting halfway through the install.
    # They're turned back on when the installer exits, even if it fails.
    for unit in "${APT_TIMERS[@]}"; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            systemctl stop "$unit" && APT_TIMERS_PAUSED+=("$unit")
        fi
    done
    trap resume_apt_timers EXIT
    ok "apt is free${APT_TIMERS_PAUSED[*]:+ (automatic updates paused until the install ends)}"
}

resume_apt_timers() {
    [[ ${#APT_TIMERS_PAUSED[@]} -gt 0 ]] && systemctl start "${APT_TIMERS_PAUSED[@]}" 2>/dev/null
    return 0
}

# ════════════════════════════════════════════════════════════════════════════
#  2. Packages
# ════════════════════════════════════════════════════════════════════════════

install_base_packages() {
    apt_update
    apt_install ca-certificates curl jq gnupg python3 nftables iproute2 usbutils
    ok "curl, jq, gnupg, python3, nftables"
}

# ════════════════════════════════════════════════════════════════════════════
#  3. OpenStint decoder
# ════════════════════════════════════════════════════════════════════════════

OPENSTINT_RESTART=0

install_openstint_apt() {
    # Upstream's repo is unsigned ([trusted=yes]): pin it to the openstint
    # package only, so nothing else can ever come from it.
    write_file /etc/apt/preferences.d/openstint.pref 0644 <<EOF && APT_UPDATED=0 || true
# Managed by RC Race HQ install.sh. Only the decoder may come from this repo.
Package: openstint
Pin: origin "${OPENSTINT_APT_ORIGIN}"
Pin-Priority: 500

Package: *
Pin: origin "${OPENSTINT_APT_ORIGIN}"
Pin-Priority: -1
EOF
    write_file /etc/apt/sources.list.d/openstint.list 0644 <<EOF && APT_UPDATED=0 || true
# Managed by RC Race HQ install.sh. Pinned in /etc/apt/preferences.d/openstint.pref.
deb [trusted=yes arch=arm64] ${OPENSTINT_APT_URL} /
EOF
    apt_update
    is_installed openstint || OPENSTINT_RESTART=1
    apt_install openstint python3-zmq
    ok "openstint $(dpkg-query -W -f='${Version}' openstint) (upstream package)"
}

install_openstint_source() {
    # Ubuntu: upstream's .deb needs a newer libliquid, so build the same
    # package here from a pinned commit with upstream's own packaging script.
    rm -f /etc/apt/sources.list.d/openstint.list /etc/apt/preferences.d/openstint.pref

    apt_install build-essential cmake ninja-build pkg-config git dpkg-dev \
        libusb-1.0-0-dev libzmq3-dev cppzmq-dev libliquid-dev libfec-dev python3-zmq

    local want="+git${OPENSTINT_SRC_COMMIT:0:7}" have
    have=$(dpkg-query -W -f='${Version}' openstint 2>/dev/null || true)
    if [[ $have == *"$want" ]]; then
        ok "openstint $have (already built from the pinned commit)"
        return
    fi

    info "Building OpenStint ${OPENSTINT_SRC_COMMIT:0:7} (5-10 minutes on a Pi 4)..."

    # nfpm: the packager upstream uses. Checksum-pinned.
    local nfpm_deb="/var/cache/apt/archives/nfpm_${NFPM_VERSION}_arm64.deb"
    if [[ ! -f $nfpm_deb ]] || ! echo "${NFPM_SHA256_ARM64}  ${nfpm_deb}" | sha256sum -c --status 2>/dev/null; then
        curl -fsSL --retry 3 -o "$nfpm_deb" \
            "https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/nfpm_${NFPM_VERSION}_arm64.deb"
        echo "${NFPM_SHA256_ARM64}  ${nfpm_deb}" | sha256sum -c --status \
            || die "nfpm download doesn't match its pinned checksum. Not installing it."
    fi
    apt_install "$nfpm_deb"

    # Build as an unprivileged user; only the install is root.
    id "$OPENSTINT_BUILD_USER" >/dev/null 2>&1 \
        || useradd --system --home-dir "$OPENSTINT_BUILD_DIR" --create-home \
                   --shell /usr/sbin/nologin "$OPENSTINT_BUILD_USER"

    local src="${OPENSTINT_BUILD_DIR}/src"
    as_builder() { runuser -u "$OPENSTINT_BUILD_USER" -- "$@"; }

    [[ -d $src/.git ]] || as_builder git clone -q "$OPENSTINT_SRC_REPO" "$src"
    as_builder git -C "$src" fetch -q origin
    as_builder git -C "$src" checkout -q --force "$OPENSTINT_SRC_COMMIT"

    local date version
    date=$(as_builder git -C "$src" show -s --format=%cd --date=format:%y%m%d HEAD)
    version="0.${date}.0${want}"

    # Fresh build tree each time, so a stale CMake cache can't mix versions.
    rm -rf "$src/build" "$src/dist"
    ( cd "$src" \
        && as_builder cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DSAMPLES_PER_SYMBOL=2 -B build . >/dev/null \
        && as_builder ninja -C build >/dev/null \
        && as_builder env VERSION="$version" OUT_DIR=dist packaging/build-deb.sh >/dev/null )

    apt_install "$src/dist/openstint_${version}_arm64.deb"
    OPENSTINT_RESTART=1
    ok "openstint $version (built from source)"
}

setup_openstint() {
    if [[ $OPENSTINT_METHOD == apt ]]; then
        install_openstint_apt
    else
        install_openstint_source
    fi

    # The RTL2832U is an SDR here, not a TV tuner: keep the DVB-T driver off it.
    write_file /etc/modprobe.d/blacklist-rtlsdr-dvb.conf 0644 <<'EOF' || true
# Managed by RC Race HQ install.sh. The RTL2832U is an SDR here, not a TV tuner.
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
EOF
    modprobe -r dvb_usb_rtl28xxu 2>/dev/null || true

    # A dongle plugged in during install keeps root-only permissions until
    # udev re-applies the rtl-sdr rule ("usb_open error -3" otherwise).
    udevadm control --reload-rules
    udevadm trigger --action=add --subsystem-match=usb --attr-match=idVendor=0bda
    udevadm settle || true

    write_file /etc/openstint.conf 0644 <<EOF && OPENSTINT_RESTART=1 || true
# /etc/openstint.conf -- managed by RC Race HQ install.sh (re-running it rewrites this).
# systemd EnvironmentFile: -g gain, -s .rc4 folder, -p ZeroMQ port.
OPENSTINT_ARGS="-g ${OPENSTINT_GAIN} -s ${RC4_DIR} -p ${OPENSTINT_ZMQ_PORT}"
EOF

    # Your login user can rename/delete learned .rc4 files without sudo.
    usermod -aG users "$TARGET_USER"

    local learn
    learn=$(mktemp)
    fetch_repo_file files/openstint-learn "$learn"
    install -o root -g root -m 0755 "$learn" /usr/local/bin/openstint-learn
    rm -f "$learn"

    systemctl enable --quiet openstint.service
    if [[ $OPENSTINT_RESTART -eq 1 ]]; then
        systemctl restart openstint.service
    else
        systemctl start openstint.service
    fi
    ok "openstint.service $(systemctl is-active openstint.service), openstint-learn installed"

    if lsusb | grep -qiE '0bda:283[28]'; then
        ok "RTL-SDR found on USB"
    else
        warn "No RTL-SDR on USB yet. Plug it in; the decoder retries every 5 seconds."
    fi
}

# ════════════════════════════════════════════════════════════════════════════
#  4. Hostname + event Wi-Fi
# ════════════════════════════════════════════════════════════════════════════

setup_hostname() {
    [[ -n $NEW_HOSTNAME ]] || return 0
    hostnamectl set-hostname "$NEW_HOSTNAME"
    if grep -qE '^127\.0\.1\.1\s' /etc/hosts; then
        sed -i -E "s/^127\.0\.1\.1\s.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >>/etc/hosts
    fi
    # Ubuntu images: stop cloud-init putting the old name back at boot.
    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
        write_file /etc/cloud/cloud.cfg.d/99-race-network-hostname.cfg 0644 <<'EOF' || true
# Managed by RC Race HQ install.sh
preserve_hostname: true
EOF
    fi
    ok "Hostname: $NEW_HOSTNAME"
}

setup_network_manager() {
    if [[ $OS_ID == ubuntu ]]; then
        # Ubuntu Server runs netplan/networkd. Add NetworkManager next to it for
        # Wi-Fi only (Ubuntu's package leaves eth0 to networkd, so SSH stays up).
        if netplan get wifis 2>/dev/null | grep -q "^${WIFI_IF}:"; then
            die "netplan configures ${WIFI_IF} under 'wifis:' (see /etc/netplan/).
  Remove that block, run 'sudo netplan apply', then run this again."
        fi
        apt_install network-manager
        systemctl enable --now --quiet NetworkManager.service
    fi
    [[ $(nmcli -t -f RUNNING general 2>/dev/null) == running ]] \
        || die "NetworkManager isn't running; it's needed for the event Wi-Fi."
}

setup_wifi_country() {
    # Raspberry Pi OS keeps Wi-Fi blocked until a country is set.
    if command -v raspi-config >/dev/null; then
        if [[ $(raspi-config nonint get_wifi_country 2>/dev/null | tr -d '[:space:]') != "$AP_COUNTRY" ]]; then
            raspi-config nonint do_wifi_country "$AP_COUNTRY"
        fi
    else
        apt_install iw rfkill
        write_file /etc/modprobe.d/race-hotspot-regdom.conf 0644 \
            <<<"options cfg80211 ieee80211_regdom=${AP_COUNTRY}" || true
        iw reg get | grep -q "country ${AP_COUNTRY}:" || iw reg set "$AP_COUNTRY"
        rfkill unblock wifi
    fi
    ok "Wi-Fi country $AP_COUNTRY"
}

setup_ap_profile() {
    local con=race-hotspot
    local keyfile="/etc/NetworkManager/system-connections/${con}.nmconnection"

    # Write the profile as a plain NetworkManager keyfile. On Ubuntu,
    # "nmcli connection add/modify" stores profiles through netplan, and netplan
    # turns a Wi-Fi access point into "shared" mode. That starts
    # NetworkManager's own dnsmasq on wlan0, which then blocks ours (port 53/67).
    local uuid=""
    [[ -f $keyfile ]] && uuid=$(sed -n 's/^uuid=//p' "$keyfile" | head -1)
    [[ -n $uuid ]] || uuid=$(cat /proc/sys/kernel/random/uuid)

    # Remove every other copy of the profile (e.g. a netplan-backed one from an
    # earlier install) plus NetworkManager's default "Hotspot" profile.
    local id other file
    while IFS=: read -r id other file; do
        [[ $id == "$con" || $id == Hotspot ]] || continue
        [[ $other == "$uuid" && $file == "$keyfile" ]] && continue
        nmcli connection delete "$other" >/dev/null
        info "Removed old Wi-Fi profile '$id' ($other)"
    done < <(nmcli -t -f NAME,UUID,FILENAME connection show 2>/dev/null)

    local security=""
    if [[ -n $AP_PASSPHRASE ]]; then
        security=$'\n[wifi-security]\nkey-mgmt=wpa-psk\nproto=rsn\npsk='"${AP_PASSPHRASE}"$'\n'
    fi

    write_file "$keyfile" 0600 <<EOF || true
# Managed by RC Race HQ install.sh (re-running it rewrites this).
# ipv4 is manual, not shared: dnsmasq.service does DHCP/DNS for the event Wi-Fi.
[connection]
id=${con}
uuid=${uuid}
type=wifi
interface-name=${WIFI_IF}
autoconnect=true
autoconnect-priority=100

[wifi]
mode=ap
ssid=${AP_SSID}
band=bg
channel=6
powersave=2
${security}
[ipv4]
method=manual
address1=${AP_ADDRESS}/${AP_PREFIX}

[ipv6]
method=disabled
EOF

    nmcli connection reload
    nmcli connection up "$con" >/dev/null

    [[ $(nmcli -g ipv4.method connection show "$con") == manual ]] \
        || die "The '$con' Wi-Fi profile isn't in manual mode (NetworkManager would run its own dnsmasq).
  Check: nmcli -f NAME,UUID,FILENAME connection show; ls /etc/netplan/"
    ok "Wi-Fi \"$AP_SSID\" ($([[ -n $AP_PASSPHRASE ]] && echo WPA2 || echo open)) on $WIFI_IF, ${AP_ADDRESS}"
}

setup_dnsmasq() {
    apt_install dnsmasq
    local conf
    conf=$(mktemp)
    cat >"$conf" <<EOF
# Managed by RC Race HQ install.sh. DHCP + DNS for the event Wi-Fi only.

# Only serve the event LAN; leave the Pi's own resolver alone.
interface=${WIFI_IF}
except-interface=lo
bind-dynamic

# DNS: http://${AP_HOSTNAME}/ answers locally, everything else goes upstream.
domain-needed
bogus-priv
cache-size=1000
domain=${AP_DOMAIN}
local=/${AP_DOMAIN}/
address=/${AP_HOSTNAME}/${AP_ADDRESS}
address=/${AP_HOSTNAME}.${AP_DOMAIN}/${AP_ADDRESS}

# DHCP
dhcp-authoritative
dhcp-range=${WIFI_IF},${AP_DHCP_START},${AP_DHCP_END},${AP_NETMASK},12h
dhcp-option=${WIFI_IF},option:router,${AP_ADDRESS}
dhcp-option=${WIFI_IF},option:dns-server,${AP_ADDRESS}
dhcp-option=${WIFI_IF},option:domain-search,${AP_DOMAIN}
EOF
    dnsmasq --test --conf-file="$conf" >/dev/null 2>&1 || { rm -f "$conf"; die "dnsmasq rejected its config"; }
    local changed=0
    write_file /etc/dnsmasq.d/race-dns.conf 0644 <"$conf" && changed=1 || true
    rm -f "$conf"

    # Check the whole config dnsmasq will load, not just our file: leftovers
    # in /etc/dnsmasq.conf or /etc/dnsmasq.d can clash with it.
    dnsmasq --test >/dev/null 2>&1 \
        || die "dnsmasq's full config is invalid: $(dnsmasq --test 2>&1 | tail -1)
  Check /etc/dnsmasq.conf and other files in /etc/dnsmasq.d/."

    # NetworkManager runs its own dnsmasq for "shared" profiles; it holds the
    # same ports, so ours can't start.
    if pgrep -f -- '--conf-file=/dev/null --no-hosts' >/dev/null; then
        die "NetworkManager is running its own dnsmasq (a Wi-Fi profile in 'shared' mode).
  Find it with: nmcli -f NAME,UUID,FILENAME connection show
  Delete that profile (and any /etc/netplan/90-NM-*.yaml for it), then run this again."
    fi

    systemctl enable --quiet dnsmasq.service
    local action=start
    [[ $changed -eq 1 ]] && action=restart
    if ! systemctl "$action" dnsmasq.service; then
        warn "dnsmasq didn't start. Its last log lines:"
        journalctl -u dnsmasq.service -n 15 --no-pager -o cat >&2 || true
        warn "What else is using the DNS/DHCP ports (53, 67):"
        ss -lnup '( sport = :53 or sport = :67 )' >&2 || true
        die "dnsmasq failed to start (details above)."
    fi
    ok "dnsmasq: DHCP ${AP_DHCP_START}-${AP_DHCP_END}, http://${AP_HOSTNAME}/ -> ${AP_ADDRESS}"
}

setup_portal_firewall() {
    # Forwarding so let-through phones can reach the internet over eth0.
    write_file /etc/sysctl.d/90-race-hotspot.conf 0644 <<'EOF' && sysctl --system >/dev/null || true
# Managed by RC Race HQ install.sh: event Wi-Fi clients -> eth0 NAT.
net.ipv4.ip_forward = 1
EOF

    # Own nftables table only; never touches the rest of the ruleset.
    local rules
    rules=$(mktemp)
    cat >"$rules" <<EOF
#!/usr/sbin/nft -f
# Managed by RC Race HQ install.sh. Loaded by race-portal-firewall.service.
table inet race_portal
delete table inet race_portal

table inet race_portal {
	# Phones that opened http://${AP_HOSTNAME}/ (added by race-portal).
	set allowed {
		type ipv4_addr
		flags timeout
	}

	# Not let through yet: send every plain-HTTP request to the portal.
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		iifname "${WIFI_IF}" ip daddr != ${AP_ADDRESS} ip saddr != @allowed tcp dport 80 dnat ip to ${AP_ADDRESS}:${PORTAL_PORT}
	}

	# The open Wi-Fi only reaches DHCP, DNS and the portal on the Pi.
	chain input {
		type filter hook input priority filter; policy accept;
		iifname != "${WIFI_IF}" accept
		ct state established,related accept
		meta l4proto icmp accept
		tcp dport { 53, ${PORTAL_PORT} } accept
		udp dport { 53, 67 } accept
		drop
	}

	chain forward {
		type filter hook forward priority filter; policy accept;
		oifname "${WIFI_IF}" ct state established,related accept
		oifname "${WIFI_IF}" drop
		iifname "${WIFI_IF}" ip saddr @allowed oifname { "${WIRED_IF}" } accept
		# Fail fast (HTTPS etc.) instead of hanging until the portal is opened.
		iifname "${WIFI_IF}" meta l4proto tcp reject with tcp reset
		iifname "${WIFI_IF}" reject with icmpx type admin-prohibited
	}

	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		iifname "${WIFI_IF}" oifname { "${WIRED_IF}" } masquerade
	}
}
EOF
    nft -c -f "$rules" || { rm -f "$rules"; die "nftables rejected the portal ruleset"; }
    install -d -m 0755 /etc/race
    write_file /etc/race/race-portal.nft 0644 <"$rules" || true
    rm -f "$rules"

    write_file /etc/systemd/system/race-portal-firewall.service 0644 <<'EOF' || true
# Managed by RC Race HQ install.sh.
[Unit]
Description=Lap counter hotspot firewall (captive portal + NAT)
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/race/race-portal.nft
ExecStop=/usr/sbin/nft delete table inet race_portal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --quiet race-portal-firewall.service
    systemctl restart race-portal-firewall.service
    ok "Firewall: Wi-Fi reaches only DHCP, DNS and the portal until let through"
}

# The portal serves the app on port 80: http://race/ on the event Wi-Fi and
# http://<hostname>.local/ on the wired side. With --no-ap it runs wired-only.
setup_portal() {
    local portal
    portal=$(mktemp)
    fetch_repo_file files/race-portal "$portal"
    install -o root -g root -m 0755 "$portal" /usr/local/sbin/race-portal
    rm -f "$portal"

    local requires="" caps="CAP_NET_BIND_SERVICE" families="AF_INET AF_UNIX"
    if [[ $WITH_AP -eq 1 ]]; then
        requires="Requires=race-portal-firewall.service"
        caps="CAP_NET_ADMIN CAP_NET_BIND_SERVICE"
        families="AF_INET AF_UNIX AF_NETLINK"
    fi

    write_file /etc/systemd/system/race-portal.service 0644 <<EOF || true
# Managed by RC Race HQ install.sh.
[Unit]
Description=Lap counter captive portal (http://${AP_HOSTNAME}/)
After=race-portal-firewall.service NetworkManager.service
${requires}

[Service]
Environment=PORTAL_GATEWAY=${AP_ADDRESS}
Environment=PORTAL_PREFIX=${AP_PREFIX}
Environment=PORTAL_LISTEN=0.0.0.0
Environment=PORTAL_PORT=${PORTAL_PORT}
Environment=PORTAL_HOSTNAME=${AP_HOSTNAME}
Environment=PORTAL_DOMAIN=${AP_DOMAIN}
Environment=PORTAL_TIMEOUT=12h
Environment=PORTAL_APP_PORT=${APP_PORT}
Environment="PORTAL_TITLE=${AP_SSID}"
ExecStart=/usr/bin/python3 -I /usr/local/sbin/race-portal
Restart=always
RestartSec=2

DynamicUser=yes
AmbientCapabilities=${caps}
CapabilityBoundingSet=${caps}
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
RestrictAddressFamilies=${families}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --quiet race-portal.service
    systemctl restart race-portal.service

    # Publish http://<hostname>.local/ on the wired side.
    apt_install avahi-daemon
    write_file /etc/avahi/services/race-web.service 0644 <<'EOF' || true
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<!-- Managed by RC Race HQ install.sh -->
<service-group>
  <name replace-wildcards="yes">RC Race HQ lap counter (%h)</name>
  <service>
    <type>_http._tcp</type>
    <port>80</port>
    <txt-record>path=/</txt-record>
  </service>
</service-group>
EOF
    systemctl enable --now --quiet avahi-daemon.service
    ok "Portal on :${PORTAL_PORT} -> app on :${APP_PORT}"
}

# --no-ap after an earlier install with the AP: take the Wi-Fi parts back out.
remove_ap() {
    local removed=0
    if command -v nmcli >/dev/null && nmcli -t -f NAME connection show 2>/dev/null | grep -qx race-hotspot; then
        nmcli connection delete race-hotspot >/dev/null; removed=1
    fi
    if [[ -f /etc/systemd/system/race-portal-firewall.service ]]; then
        systemctl disable --now --quiet race-portal-firewall.service || true
        rm -f /etc/systemd/system/race-portal-firewall.service /etc/race/race-portal.nft
        removed=1
    fi
    if [[ -f /etc/dnsmasq.d/race-dns.conf ]]; then
        rm -f /etc/dnsmasq.d/race-dns.conf
        systemctl disable --now --quiet dnsmasq.service || true
        removed=1
    fi
    rm -f /etc/sysctl.d/90-race-hotspot.conf
    systemctl daemon-reload
    if [[ $removed -eq 1 ]]; then ok "Removed the event Wi-Fi from an earlier install"; fi
    info "Event Wi-Fi skipped (--no-ap). $WIFI_IF is left as the OS set it up."
}

setup_network() {
    setup_hostname
    if [[ $WITH_AP -eq 1 ]]; then
        setup_network_manager
        setup_wifi_country
        setup_ap_profile
        setup_dnsmasq
        setup_portal_firewall
    else
        remove_ap
    fi
    setup_portal
}

# ════════════════════════════════════════════════════════════════════════════
#  5. Docker
# ════════════════════════════════════════════════════════════════════════════

setup_docker() {
    # Podman's "docker" stand-in and distro Docker packages clash with Docker's own.
    local pkg conflicts=()
    for pkg in podman-docker docker.io docker-doc docker-compose docker-compose-v2 containerd runc; do
        is_installed "$pkg" && conflicts+=("$pkg")
    done
    if [[ ${#conflicts[@]} -gt 0 ]]; then
        info "Removing packages that clash with Docker Engine: ${conflicts[*]}"
        apt_get remove -y "${conflicts[@]}" >/dev/null
    fi

    local url="https://download.docker.com/linux/${OS_ID}"

    # Docker's signing key, refused unless the fingerprint matches.
    local key
    key=$(mktemp)
    curl -fsSL --retry 3 "${url}/gpg" -o "$key"
    gpg --show-keys --with-colons "$key" 2>/dev/null | awk -F: '$1 == "fpr" {print $10}' \
        | grep -qx "$DOCKER_GPG_FINGERPRINT" \
        || { rm -f "$key"; die "Docker's apt key doesn't have the expected fingerprint. Not installing it."; }
    install -d -m 0755 /etc/apt/keyrings
    write_file /etc/apt/keyrings/docker.asc 0644 <"$key" && APT_UPDATED=0 || true
    rm -f "$key"

    # Brand-new OS releases can appear before Docker publishes a repo for them.
    local suite=$OS_CODENAME
    if ! curl -fsSI -m 15 "${url}/dists/${suite}/Release" >/dev/null 2>&1; then
        local fallback
        fallback=$([[ $OS_ID == ubuntu ]] && echo noble || echo trixie)
        warn "Docker has no '${suite}' repo yet; using '${fallback}' packages."
        suite=$fallback
    fi

    write_file /etc/apt/sources.list.d/docker.sources 0644 <<EOF && APT_UPDATED=0 || true
# Managed by RC Race HQ install.sh. Key fingerprint checked by the installer.
Types: deb
URIs: ${url}
Suites: ${suite}
Components: stable
Architectures: arm64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt_update
    apt_install docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Rotate container logs so a chatty container can't fill the SD card.
    local docker_restart=0
    write_file /etc/docker/daemon.json 0644 <<'EOF' && docker_restart=1 || true
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    systemctl enable --now --quiet docker.service
    [[ $docker_restart -eq 0 ]] || systemctl restart docker.service
    ok "$(docker --version)"
}

# ════════════════════════════════════════════════════════════════════════════
#  6. App
# ════════════════════════════════════════════════════════════════════════════

RESOLVED_TAG=""; IMAGE_REF=""

# Anonymous pull token (or a login, for a private image).
registry_token() {
    local auth=()
    [[ -n ${GHCR_TOKEN:-} ]] && auth=(-u "${GHCR_USER:-token}:${GHCR_TOKEN}")
    curl -fsSL "${auth[@]}" \
        "https://${REGISTRY}/token?service=${REGISTRY}&scope=repository:${IMAGE_PATH}:pull" | jq -r .token
}

# GET a manifest or blob. Prints the body.
registry_get() {
    local token=$1 what=$2
    curl -fsSL -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "https://${REGISTRY}/v2/${IMAGE_PATH}/${what}"
}

# latest -> the exact build it points at today (sha-<7>), so the Pi never
# changes under you. Any other tag is just checked to exist.
resolve_tag() {
    local token manifest
    token=$(registry_token) || die "Can't get a pull token from ${REGISTRY}. Is the image public?"
    manifest=$(registry_get "$token" "manifests/${TAG}") \
        || die "Image tag '${TAG}' not found in ${IMAGE_REPO}."

    if [[ $TAG != latest ]]; then
        RESOLVED_TAG=$TAG
    else
        # A multi-arch index: use its arm64 entry.
        if jq -e '.manifests' >/dev/null <<<"$manifest"; then
            local digest
            digest=$(jq -r '.manifests[] | select(.platform.architecture == "arm64") | .digest' <<<"$manifest" | head -1)
            [[ -n $digest ]] || die "latest has no arm64 image."
            manifest=$(registry_get "$token" "manifests/${digest}")
        fi
        local config revision
        config=$(registry_get "$token" "blobs/$(jq -r .config.digest <<<"$manifest")")
        revision=$(jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' <<<"$config")
        if [[ $revision =~ ^[0-9a-f]{7,40}$ ]] && registry_get "$token" "manifests/sha-${revision:0:7}" >/dev/null 2>&1; then
            RESOLVED_TAG="sha-${revision:0:7}"
        else
            die "Couldn't work out which build 'latest' is. Pass a tag instead, e.g. sha-1a2b3c4."
        fi
    fi
    IMAGE_REF="${IMAGE_REPO}:${RESOLVED_TAG}"
    ok "Image ${IMAGE_REF}$([[ $TAG == latest ]] && echo '  (latest today)')"
}

setup_app() {
    resolve_tag

    # Private image only: same file `docker login` writes, root-only.
    if [[ -n ${GHCR_TOKEN:-} ]]; then
        install -d -m 0700 /root/.docker
        write_file /root/.docker/config.json 0600 <<EOF || true
{ "auths": { "${REGISTRY}": { "auth": "$(printf '%s:%s' "${GHCR_USER:-token}" "$GHCR_TOKEN" | base64 -w0)" } } }
EOF
    fi

    install -d -o root -g root -m 0755 "$APP_DIR"
    install -d -o "$APP_UID" -g "$APP_UID" -m 0750 "$APP_DATA_DIR"

    # The web container renames learned .rc4 files, so it joins that folder's group.
    [[ -d $RC4_DIR ]] || die "$RC4_DIR is missing; the openstint package should have created it."
    [[ $(( 8#$(stat -c %a "$RC4_DIR") & 8#020 )) -ne 0 ]] || die "$RC4_DIR isn't group-writable."
    local rc4_gid
    rc4_gid=$(stat -c %g "$RC4_DIR")

    write_file "${APP_DIR}/compose.yaml" 0644 <<EOF || true
# Managed by RC Race HQ install.sh (re-run it to change the image).
# Host networking: lapd reads the decoder on 127.0.0.1. web listens on
# 127.0.0.1:${APP_PORT} only; everyone uses port 80 (race-portal), which proxies to it.
name: lapcounter
services:
  web:
    image: "${IMAGE_REF}"
    network_mode: host
    restart: unless-stopped
    # Same as the image's CMD, but bound to the Pi itself (no outside :${APP_PORT}).
    command: ["gunicorn", "--worker-class", "gthread", "--workers", "2", "--threads", "16",
              "--bind", "127.0.0.1:${APP_PORT}", "--access-logfile", "-", "lapcounter.web:create_app()"]
    environment:
      LAPCOUNTER_DB: ${APP_DATA_DIR}/lapcounter.db
      LAPCOUNTER_DECODER_STALE_S: "5"
      OPENSTINT_RC4_DIR: "${RC4_DIR}"
      # Settings -> Link pairs this Pi with a track in RC Race HQ.
      RCRACEHQ_API_URL: "${RCRACEHQ_API_URL}"
    group_add: ["${rc4_gid}"]
    volumes:
      - ${APP_DATA_DIR}:${APP_DATA_DIR}
      - ${RC4_DIR}:${RC4_DIR}
  lapd:
    image: "${IMAGE_REF}"
    network_mode: host
    restart: unless-stopped
    command: ["python", "-m", "lapcounter.lapd"]
    healthcheck:
      disable: true
    environment:
      LAPCOUNTER_DB: ${APP_DATA_DIR}/lapcounter.db
      OPENSTINT_ZMQ: "tcp://127.0.0.1:${OPENSTINT_ZMQ_PORT}"
    volumes:
      - ${APP_DATA_DIR}:${APP_DATA_DIR}
  # Uploads learned transponders and results to RC Race HQ once paired.
  syncd:
    image: "${IMAGE_REF}"
    network_mode: host
    restart: unless-stopped
    command: ["python", "-m", "lapcounter.syncd"]
    healthcheck:
      disable: true
    environment:
      LAPCOUNTER_DB: ${APP_DATA_DIR}/lapcounter.db
      OPENSTINT_RC4_DIR: "${RC4_DIR}"
    volumes:
      - ${APP_DATA_DIR}:${APP_DATA_DIR}
      - ${RC4_DIR}:${RC4_DIR}:ro
EOF

    info "Pulling and starting the app (first pull takes a few minutes)..."
    ( cd "$APP_DIR" && docker compose up -d --pull missing --remove-orphans --wait --wait-timeout 180 >/dev/null )
    ok "Containers: $(cd "$APP_DIR" && docker compose ps --format '{{.Service}}={{.State}}' | paste -sd ' ')"
}

# ════════════════════════════════════════════════════════════════════════════
#  7. Status screen
# ════════════════════════════════════════════════════════════════════════════

# ── Small SPI LCD (--lcd) ───────────────────────────────────────────────────
# Both OSes read /boot/firmware/config.txt. Where the overlay file goes differs:
#   Raspberry Pi OS  /boot/firmware/overlays/
#   Ubuntu           /boot/firmware/current/overlays/ (A/B boot; a kernel
#                    update fills new/ and then swaps it in)
# So the file is kept in LCD_SHARE_DIR and copied into every overlays folder
# that exists, now and by a hook after each kernel/initramfs update.

LCD_REBOOT=0

lcd_boot_dir() {
    if [[ -f /boot/firmware/config.txt ]]; then echo /boot/firmware
    elif [[ -f /boot/config.txt ]]; then echo /boot
    else return 1
    fi
}

# Print the config.txt with our block removed and any other line that loads
# a 3.5" LCD overlay commented out (only one may own the SPI bus). With $2 set,
# append our block (under [all], so a [pi4]/[cm4] section can't hide it).
lcd_config_text() {
    local config=$1 block=${2:-}
    awk -v begin="$LCD_BEGIN" -v end="$LCD_END" '
        $0 == begin { skip = 1; next }
        $0 == end   { skip = 0; next }
        skip        { next }
        /^[[:space:]]*dtoverlay=(waveshare35[a-z]*|piscreen|tft35a)([,:].*)?[[:space:]]*$/ {
            print "#" $0 "   # disabled by RC Race HQ install.sh (--lcd)"; next
        }
        { print }
    ' "$config"
    [[ -z $block ]] || printf '%s\n' "$block"
}

lcd_overlay_dirs() {
    local boot=$1 d
    for d in "$boot/current/overlays" "$boot/new/overlays" "$boot/overlays"; do
        if [[ -d $d ]]; then echo "$d"; fi
    done
    return 0
}

remove_lcd() {
    local boot config
    boot=$(lcd_boot_dir) || return 0
    config="$boot/config.txt"
    if grep -qxF "$LCD_BEGIN" "$config"; then
        lcd_config_text "$config" | write_file "$config" 0755 && LCD_REBOOT=1 || true
    fi
    if [[ -d $LCD_SHARE_DIR ]]; then
        local f d
        for f in "$LCD_SHARE_DIR"/*.dtbo; do
            [[ -f $f ]] || continue
            while read -r d; do rm -f "$d/$(basename "$f")"; done < <(lcd_overlay_dirs "$boot")
        done
        rm -rf "$LCD_SHARE_DIR"
    fi
    rm -f "/etc/kernel/postinst.d/$LCD_HOOK_NAME" "/etc/initramfs/post-update.d/$LCD_HOOK_NAME"
    ok "LCD removed$([[ $LCD_REBOOT -eq 1 ]] && echo '; reboot to finish')"
}

setup_lcd() {
    case $LCD_MODEL in
        "")   grep -qsxF "$LCD_BEGIN" "$(lcd_boot_dir 2>/dev/null)/config.txt" \
                  && info "LCD: keeping the one set up earlier (--lcd none removes it)"
              return 0 ;;
        none) remove_lcd; return 0 ;;
    esac

    lcd_profile "$LCD_MODEL"
    local boot config tmp dtbo
    boot=$(lcd_boot_dir) || die "No config.txt in /boot/firmware or /boot; is this a Raspberry Pi image?"
    config="$boot/config.txt"

    # 1. The overlay file, checked.
    dtbo="$LCD_SHARE_DIR/${LCD_OVERLAY}.dtbo"
    if ! { [[ -f $dtbo ]] && echo "$LCD_SHA256  $dtbo" | sha256sum -c --status; }; then
        tmp=$(mktemp)
        curl -fsSL --retry 3 --max-time 60 "$LCD_URL" -o "$tmp" \
            || { rm -f "$tmp"; die "Couldn't download the $LCD_MODEL overlay from $LCD_URL"; }
        echo "$LCD_SHA256  $tmp" | sha256sum -c --status \
            || { rm -f "$tmp"; die "The $LCD_MODEL overlay download doesn't match its checksum; not installing it."; }
        install -D -o root -g root -m 0644 "$tmp" "$dtbo"
        rm -f "$tmp"
    fi

    # 2. Copy it into every overlays folder, now and after kernel updates.
    write_file "/etc/kernel/postinst.d/$LCD_HOOK_NAME" 0755 <<EOF || true
#!/bin/sh
# Managed by RC Race HQ install.sh (--lcd). Kernel and firmware updates can
# rewrite the boot partition's overlays folder; put the LCD overlay back.
for f in ${LCD_SHARE_DIR}/*.dtbo; do
    [ -f "\$f" ] || continue
    for d in ${boot}/current/overlays ${boot}/new/overlays ${boot}/overlays; do
        [ -d "\$d" ] && cp -f "\$f" "\$d/"
    done
done
exit 0
EOF
    if [[ -d /etc/initramfs/post-update.d ]]; then
        install -o root -g root -m 0755 "/etc/kernel/postinst.d/$LCD_HOOK_NAME" \
            "/etc/initramfs/post-update.d/$LCD_HOOK_NAME"
    fi
    local dirs d
    dirs=$(lcd_overlay_dirs "$boot")
    [[ -n $dirs ]] || die "No overlays folder under $boot (looked for current/, new/ and overlays/)."
    while read -r d; do
        cmp -s "$dtbo" "$d/${LCD_OVERLAY}.dtbo" || { cp -f "$dtbo" "$d/"; LCD_REBOOT=1; }
    done <<<"$dirs"

    # 3. config.txt: SPI on and the overlay, in our own [all] block at the end.
    local block
    block=$(printf '%s\n[all]\ndtparam=spi=on\ndtoverlay=%s,rotate=%s\n%s' \
        "$LCD_BEGIN" "$LCD_OVERLAY" "$LCD_ROTATE" "$LCD_END")
    # Keep the original once, before the first change.
    [[ -f $config.lapcounter-bak ]] || cp -p "$config" "$config.lapcounter-bak"
    if lcd_config_text "$config" "$block" | write_file "$config" 0755; then
        LCD_REBOOT=1
    fi

    if [[ $LCD_REBOOT -eq 0 ]] && grep -qs '^fb_' /sys/class/graphics/fb*/name; then
        ok "LCD $LCD_MODEL (rotate $LCD_ROTATE) is on"
    else
        LCD_REBOOT=1
        ok "LCD $LCD_MODEL (rotate $LCD_ROTATE) set up; reboot to turn it on"
    fi
}

# The console (tty1), so an attached LCD or HDMI screen shows the wired
# IP, the event Wi-Fi, the race on track and any problems. tty1 has no login
# prompt while it runs; Alt+F2 still gives one.
setup_status_screen() {
    local unit=/etc/systemd/system/lapcounter-status.service
    if [[ $WITH_SCREEN -eq 0 ]]; then
        if [[ -f $unit ]]; then
            systemctl disable --now --quiet lapcounter-status.service || true
            rm -f "$unit" /usr/local/sbin/lapcounter-status
            systemctl daemon-reload
            systemctl start getty@tty1.service || true
        fi
        info "Status screen skipped (--no-screen)"
        return 0
    fi

    # With an LCD set up, give its driver time to load at boot so the
    # dashboard lands on the LCD and not on HDMI.
    local lcd_wait=0
    grep -qsxF "$LCD_BEGIN" "$(lcd_boot_dir 2>/dev/null)/config.txt" && lcd_wait=$LCD_WAIT_S

    # Pillow + fonts draw the colour dashboard; without a framebuffer the
    # script falls back to coloured console text.
    apt_install python3-pil fonts-dejavu-core

    local script
    script=$(mktemp)
    fetch_repo_file files/lapcounter-status "$script"
    install -o root -g root -m 0755 "$script" /usr/local/sbin/lapcounter-status
    rm -f "$script"

    write_file "$unit" 0644 <<EOF || true
# Managed by RC Race HQ install.sh.
[Unit]
Description=Lap counter status screen (tty1)
After=network-online.target openstint.service race-portal.service getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Environment=STATUS_APP_PORT=${APP_PORT}
Environment=STATUS_WIRED_IF=${WIRED_IF}
Environment=STATUS_WIFI_IF=${WIFI_IF}
Environment=STATUS_STATE_FILE=${STATE_FILE}
Environment=STATUS_LCD_WAIT=${lcd_wait}
ExecStart=/usr/bin/python3 -I /usr/local/sbin/lapcounter-status
StandardInput=null
StandardOutput=tty
StandardError=journal
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
Restart=always
RestartSec=3

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
RestrictAddressFamilies=AF_INET AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --quiet lapcounter-status.service
    systemctl restart lapcounter-status.service
    ok "Status screen on the console (tty1)"
}

# ════════════════════════════════════════════════════════════════════════════
#  8. Check
# ════════════════════════════════════════════════════════════════════════════

check_result() {
    local failed=0

    for _ in {1..20}; do
        curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${APP_PORT}/healthz" && break
        sleep 3
    done
    if curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${APP_PORT}/healthz"; then
        ok "App answers on 127.0.0.1:${APP_PORT} (Pi only)"
    else
        warn "App isn't answering on :${APP_PORT}. Logs: cd ${APP_DIR} && sudo docker compose logs web"
        failed=1
    fi

    if curl -sS -m 3 -o /dev/null "http://127.0.0.1:${PORTAL_PORT}/"; then
        ok "Portal answers on :${PORTAL_PORT}"
    else
        warn "Portal isn't answering on :${PORTAL_PORT}. Logs: journalctl -u race-portal -n 30"
        failed=1
    fi

    if systemctl is-active --quiet openstint.service; then
        ok "Decoder running"
    else
        warn "Decoder isn't running. Logs: journalctl -u openstint -n 30"
        failed=1
    fi

    local lcd_state=none boot
    if boot=$(lcd_boot_dir) && grep -qsxF "$LCD_BEGIN" "$boot/config.txt"; then
        lcd_state=$(awk -v b="$LCD_BEGIN" -v e="$LCD_END" \
            '$0 == b {in_ = 1} $0 == e {in_ = 0} in_ && sub(/^dtoverlay=/, "") {print}' "$boot/config.txt")
    fi

    write_file "$STATE_FILE" 0644 <<EOF || true
# Written by RC Race HQ install.sh on $(date -Is). For reference only.
IMAGE=${IMAGE_REF}
REQUESTED_TAG=${TAG}
EVENT_WIFI=$([[ $WITH_AP -eq 1 ]] && echo on || echo off)
SSID=${AP_SSID}
INSTALL_REF=${INSTALL_REF}
LCD=${lcd_state}
EOF
    return $failed
}

print_summary() {
    local host wired_ip
    host=$(hostname)
    wired_ip=$(ip -4 -o addr show "$WIRED_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)

    printf '\n%s== Lap counter installed ==%s\n' "$C_BOLD$C_GREEN" "$C_OFF"
    printf '  Image:        %s\n' "$IMAGE_REF"
    printf '  Wired side:   http://%s.local/   (or http://%s/)\n' "$host" "${wired_ip:-<pi address>}"
    if [[ $WITH_AP -eq 1 ]]; then
        printf '  Event Wi-Fi:  join "%s", then open http://%s/  (/checkin, /kiosk)\n' "$AP_SSID" "$AP_HOSTNAME"
    fi
    printf '  Pair a club:  open the app -> Settings -> Link, enter the code from RC Race HQ\n'
    printf '  Learn a car:  openstint-learn <transponder number>\n'
    printf '\n'
    printf '  Decoder log:  journalctl -u openstint -f   (an "S" line every second)\n'
    printf '  App logs:     cd %s && sudo docker compose logs -f\n' "$APP_DIR"
    printf '  Update:       run the installer again (same command) for the newest build\n'
    printf '\n  Log out and back in once so %s can edit learned transponder files.\n' "$TARGET_USER"
    if [[ $LCD_REBOOT -eq 1 ]]; then
        printf '\n  %sReboot to finish the LCD:%s  sudo reboot\n' "$C_BOLD$C_YELLOW" "$C_OFF"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
#  Main
# ════════════════════════════════════════════════════════════════════════════

main() {
    parse_args "$@"

    step "Checks"
    check_user
    # Everything from here on also goes to the log file.
    touch "$LOG_FILE" && chmod 0640 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    printf '\n--- %s  install.sh %s ---\n' "$(date -Is)" "$*" >>"$LOG_FILE"
    check_platform
    check_network
    check_apt

    step "Packages"
    install_base_packages

    step "OpenStint decoder"
    setup_openstint

    step "Network$([[ $WITH_AP -eq 1 ]] && echo ' + event Wi-Fi')"
    setup_network

    step "Docker"
    setup_docker

    step "Lap counter app"
    setup_app

    step "Screen"
    setup_lcd
    setup_status_screen

    step "Check"
    if check_result; then
        print_summary
    else
        print_summary
        die "Installed, but something above isn't running yet."
    fi
}

main "$@"
