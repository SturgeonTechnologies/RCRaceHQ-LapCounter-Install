# provision_race_decoder

Turns a **Raspberry Pi (or an Ubuntu 24.04+ arm64/amd64 box) + RTL-SDR** into an [OpenStint](https://github.com/zsellera/openstint)
lap-timing decoder for MYLAPS/AMB-style RC transponders, and installs
`openstint-learn`, which registers a pure RC4 transponder under the number on
its label in one command.

## What it does

On the target Pi (`become: true`):

- Picks an install method (`openstint_decoder_install_method: auto`): the
  upstream apt repo on **arm64 Debian 13 (Trixie)**, a **source build** on
  Ubuntu 24.04+ or amd64 (see [Ubuntu source build](#ubuntu-source-build)).
  Fails on anything else, and warns if the board is older than a Pi 3 Model B+.
- apt method: adds upstream's apt repo (`repo.lapbeeps.com`). That repo is **unsigned**
  (`[trusted=yes]` is upstream's own line), so the role also writes
  `/etc/apt/preferences.d/openstint.pref`: only the `openstint` package may come
  from it; anything else it publishes is blocked (priority -1).
- Installs `openstint` (decoder, udev rules, `openstint.service`) and
  `python3-zmq`. Both methods install the same package name, unit and
  conffile, so everything after this step is identical.
- Blacklists the DVB-T TV driver and re-triggers udev for RTL-SDR dongles, so a
  dongle that was plugged in before the install still gets `plugdev` perms
  (see [Troubleshooting the SDR](#troubleshooting-the-sdr)).
- Renders `/etc/openstint.conf` (gain, registry folder, ZeroMQ port).
- Adds the login user to `users`, so `.rc4` files in `/var/lib/openstint` can be
  renamed or deleted without sudo.
- Installs `/usr/local/bin/openstint-learn`.
- Enables + starts `openstint.service`; optionally locks the ZeroMQ port to one
  CIDR with `ufw`.
- Prints whether the service is active and whether an RTL-SDR is on USB.
- Sets the Pi's network: hostname, and `eth0` on DHCP (default) or a static
  address. `eth0` is the Pi's only uplink. Details:
  [configure_network.md](configure_network.md).
- Turns the built-in Wi-Fi into the open `RC Race Event` access point
  (always). New devices are sent to `http://race/`, which lets them out to
  the internet through `eth0` (NAT) and serve the app right there
  (`http://race/`: live/race status, `/checkin`, `/kiosk`). DHCP/DNS is the
  separate `race_dns` role.
  **Provision over Ethernet**: the role refuses to run if your SSH session is
  on `wlan0`. On the wired side, `http://<hostname>.local/` serves the
  same app.
  Details: [`race_hotspot`](../roles/race_hotspot/README.md).

## Prerequisites

Run everything below from the root of this repo. The playbooks sit next to
`roles/`, so Ansible finds the roles from any working directory; `ansible.cfg`
only adds the default inventory and output format.

1. **Image the Pi** with Raspberry Pi Imager (on Omarchy the Flatpak build
   works): **Raspberry Pi OS Lite (64-bit)**, Trixie;
   hostname `racedecoder`; SSH with your public key; username `pi` (or change
   `ansible_user` in `inventory/race_decoders.yml`).
2. Plug the RTL-SDR into the Pi. The loop goes to the SDR's SMA jack.
3. `ansible-galaxy collection install -r collections/requirements.yml`
   (`community.general` for the opt-in ufw step; `community.docker` is for
   `deploy_lapcounter_app.yml`).

## Run it

```bash
ansible-playbook -i inventory/race_decoders.yml provision_race_decoder.yml --syntax-check
ansible-playbook -i inventory/race_decoders.yml provision_race_decoder.yml
```

Then on the Pi: `journalctl -u openstint -f` should show an `S` line every
second.

## Variables

| Var | Default | Notes |
| --- | --- | --- |
| `openstint_decoder_gain` | `20` | `-g`; ignored in direct sampling (RTL-SDR v3) |
| `openstint_decoder_registry_dir` | `/var/lib/openstint` | `-s`; the unit's `ReadWritePaths=` expects this path |
| `openstint_decoder_zmq_port` | `5556` | `-p` |
| `openstint_decoder_extra_args` | `""` | e.g. `-b` (bias-tee) or `-d <serial>` |
| `openstint_decoder_manage_ufw` | `false` | when true: allow SSH, allow ZeroMQ from the CIDR below, deny the rest |
| `openstint_decoder_zmq_allowed_cidr` | `192.168.0.0/24` | |
| `openstint_decoder_package_state` | `present` | apt method: `latest` upgrades; don't do it on race day |
| `openstint_decoder_install_method` | `auto` | `auto`, `apt` or `source` (below) |
| `openstint_decoder_source_version` | pinned SHA | upstream commit the source build uses; bump to upgrade |
| `openstint_decoder_samples_per_symbol` | `2` | `-DSAMPLES_PER_SYMBOL`, same as upstream's Pi `.deb` |
| `openstint_decoder_nfpm_version` / `_sha256` | `2.43.0` | packager download, checksum-pinned per arch |

## Ubuntu source build

Upstream's apt repo only has an **arm64 .deb built for Trixie**. Its
dependencies don't resolve on Ubuntu 24.04 (`libliquid1 >= 1.7.0`; noble ships
1.6.0), and there is no amd64 build. So with `install_method: source` (the
`auto` default on Ubuntu or amd64) the role builds that same package on the
host:

1. Removes the upstream apt repo/pin if present.
2. Installs the build deps from upstream's `build-deb.yml` (`cmake`, `ninja`,
   `libliquid-dev`, `libfec-dev`, `libzmq3-dev`, `cppzmq-dev`, ...) and
   `nfpm` (checksum-pinned).
3. As the unprivileged `openstint-build` user, in `/var/cache/openstint-build/src`:
   checks out `openstint_decoder_source_version`, runs
   `cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DSAMPLES_PER_SYMBOL=2`, `ninja`,
   then upstream's `packaging/build-deb.sh`. CMake fetches upstream's pinned
   rtl-sdr/hackrf driver sources (statically linked). `dpkg-shlibdeps` computes
   the dependencies for *this* release and arch.
4. Installs `openstint_0.<YYMMDD>.0+git<sha7>_<arch>.deb` with apt.

The build only runs when the installed version doesn't end in the pinned
`+git<sha7>`, so reruns are no-ops. To upgrade, bump
`openstint_decoder_source_version`. The host needs internet access to GitHub
for the build.

Supported: Ubuntu 24.04 and newer, arm64 or amd64. CI runs the role on
`ubuntu-24.04` and `ubuntu-24.04-arm` and checks a rerun changes nothing.
On Ubuntu 25.10+/26.04 on a Pi, `install_method: apt` also works (its
`libliquid1` is 1.7), but `source` is the tested path.

Ubuntu notes:

- `race_hotspot` works on Ubuntu: it sets the Wi-Fi country with `iw` and
  installs NetworkManager for the hotspot only (eth0 stays on networkd). See
  the [role README](../roles/race_hotspot/README.md#safety).
- `deploy_lapcounter_app.yml` runs on arm64 Ubuntu 24.04+ (Docker's
  `linux/ubuntu` repo).
- To build by hand (what the role runs):

  ```bash
  sudo apt install build-essential cmake ninja-build pkg-config git dpkg-dev \
    libusb-1.0-0-dev libzmq3-dev cppzmq-dev libliquid-dev libfec-dev
  # plus nfpm: https://github.com/goreleaser/nfpm/releases
  git clone https://github.com/zsellera/openstint && cd openstint
  cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DSAMPLES_PER_SYMBOL=2 -B build .
  ninja -C build
  VERSION=0.$(git show -s --format=%cd --date=format:%y%m%d).0+git$(git rev-parse --short=7 HEAD) \
    packaging/build-deb.sh
  sudo apt install ./dist/openstint_*.deb
  ```

## Troubleshooting the SDR

`journalctl -u openstint -f -o cat` shows what the decoder sees.

- **`usb_open error -3` / `rtlsdr_open() failed: -3`**: a permissions problem (LIBUSB_ERROR_ACCESS). The `rtl-sdr` package's udev rule makes the dongle `0660 root:plugdev`, and the service joins `plugdev`. udev only applies a rule when a device is plugged in, so a dongle that was already connected when the package was installed stays root-only. The role re-triggers udev on every run. To fix it by hand, unplug and replug the dongle, or run:
  ```bash
  sudo udevadm control --reload-rules
  sudo udevadm trigger --action=add --subsystem-match=usb --attr-match=idVendor=0bda
  ls -l /dev/bus/usb/$(lsusb -d 0bda: | awk '{print $2"/"substr($4,1,3)}')   # want crw-rw---- root plugdev
  ```
- **`usb_claim_interface error -6`**: the DVB-T TV driver grabbed the dongle. The role blacklists it in `/etc/modprobe.d/blacklist-rtlsdr-dvb.conf`; by hand, run `sudo modprobe -r dvb_usb_rtl28xxu` and replug.
- **`No supported devices found`**: the dongle isn't on USB. Check `lsusb -d 0bda:`.

## Learning a transponder

Once the app is deployed, use **Admin → Transponders** in the web app instead
(see [deploy_lapcounter_app.md](deploy_lapcounter_app.md#transponder-learning)).
`openstint-learn` below is the SSH fallback; both follow the same rules.

Learning needs one transponder sitting **still** on the loop for about 12 s
(25 s for an RC4 Hybrid), hands off. On the Pi:

```bash
openstint-learn 8954097
```

It listens to the running decoder (it doesn't touch the radio), shows the
frame rate live, waits for `L … DONE`, renames the auto-numbered `1000.rc4` to
`8954097.rc4`, then waits for one pass with that number to confirm it. The
decoder picks up the new name within a second; no restart, so you can learn a
late arrival mid-event.

Options: `--host` (run it from the laptop against the Pi's feed; then `--dir`
must be a local copy of the folder, so on the Pi is simpler), `--timeout`,
`--verify-timeout 0` to skip the pass check. Exit codes: 0 learned, 1 bad
input/file problem, 2 no DONE before the timeout, 3 already known under a
different number.

It refuses labels 1000–9999, because the decoder hands those out to newly
learned transponders.

## Tests

```bash
python3 -m pytest roles -q   # needs pytest; pyzmq for openstint-learn's end-to-end test
```

## Roles used

- [`openstint_decoder`](../roles/openstint_decoder/README.md)
- [`race_network`](../roles/race_network/README.md) (hostname, `eth0` DHCP/static)
- [`race_hotspot`](../roles/race_hotspot/README.md) (event Wi-Fi + captive portal, always)
- [`race_dns`](../roles/race_dns/README.md) (DHCP + DNS for the hotspot, `http://race`)
