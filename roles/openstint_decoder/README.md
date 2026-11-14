# openstint_decoder

Provisions a Raspberry Pi (64-bit Raspberry Pi OS, Trixie) or an Ubuntu 24.04+
host (arm64/amd64) with an RTL-SDR as an
[OpenStint](https://github.com/zsellera/openstint) RC lap-timing decoder:

- `openstint` package, two ways (`openstint_decoder_install_method`):
  - `apt` (auto on arm64 Debian 13+): upstream's (unsigned) apt repo, pinned so
    nothing else can be installed from that repo (`tasks/install_apt.yml`)
  - `source` (auto on Ubuntu / amd64): builds the same `.deb` on the host from
    a pinned upstream commit with upstream's `packaging/build-deb.sh`, as an
    unprivileged user, then installs it (`tasks/install_source.yml`). Skipped
    when the installed version already ends in `+git<sha7>`
- `/etc/openstint.conf` from role vars
- `/usr/local/bin/openstint-learn` (`files/openstint-learn`): learns one RC4
  transponder and names its `.rc4` file after the label number
- optional ufw rule limiting the unauthenticated ZeroMQ feed to one CIDR

Usage, variables and the learn workflow:
[`docs/provision_race_decoder.md`](../../docs/provision_race_decoder.md).
Defaults with comments: [`defaults/main.yml`](defaults/main.yml).

## Requirements

- Ansible >= 2.15, `community.general` (ufw step only)
- Target: arm64 Debian 13+ (apt or source), or Ubuntu 24.04+ arm64/amd64
  (source; needs GitHub access), Pi 3 Model B+ or newer if it's a Pi,
  RTL-SDR v3/v4 or HackRF
  (HackRF needs the unit's `ExecStart` switched; not handled here)

## Tests

`tests/test_openstint_learn.py` covers message parsing, the DONE decision, the
rename (never overwrites) and an end-to-end run against a fake ZeroMQ decoder.

`tests/ubuntu_localhost.yml` is run by CI (job `openstint-ubuntu`) on
`ubuntu-24.04` and `ubuntu-24.04-arm`: full source build + install, a rerun
that must report `changed=0`, then package/binary/service checks.
