# RCRaceHQ-LapCounter-Install

Ansible that turns a Raspberry Pi 4 + RTL-SDR into an [RC Race HQ](https://www.rcracehq.com)
lap counter: the OpenStint decoder, the event Wi-Fi with its captive portal,
and the lap counter app.

The app (lapd + web UI) lives in
[RCRaceHQ-LapCounter-App](https://github.com/SturgeonTechnologies/RCRaceHQ-LapCounter-App)
and ships as a public container image, `ghcr.io/sturgeontechnologies/rcracehq-lapcounter`.
The optional RF front-end board is in
[RCRaceHQ-LapCounter-HAT](https://github.com/SturgeonTechnologies/RCRaceHQ-LapCounter-HAT).

The lap counter works on its own at the track. Event sync, uploads and the
shared transponder library need an RC Race HQ club to pair with
(Settings → Link on the Pi).

## Playbooks

| Playbook | What it does | Docs |
|---|---|---|
| `provision_race_decoder.yml` | OpenStint decoder + `openstint-learn`, event hotspot + captive portal (wlan0 always) | [docs/provision_race_decoder.md](docs/provision_race_decoder.md) |
| `configure_network.yml` | Only the Pi's network: hostname, eth0, event AP on wlan0 (also part of provisioning) | [docs/configure_network.md](docs/configure_network.md) |
| `deploy_lapcounter_app.yml` | Docker + the lap counter app from GHCR (pinned tag) | [docs/deploy_lapcounter_app.md](docs/deploy_lapcounter_app.md) |
| `site.yml` | Provision, then deploy (a new Pi) | |

## Hardware

Parts list, loop wiring and an ASCII schematic: [docs/hardware.md](docs/hardware.md).

## Quick start (new Pi)

1. Image the Pi: Raspberry Pi OS Lite (64-bit, Trixie) or Ubuntu 24.04+ arm64,
   hostname `racedecoder`, user `pi`, your SSH key. Plug in the RTL-SDR and Ethernet.
2. On your laptop, from this repo:

   ```bash
   ansible-galaxy collection install -r collections/requirements.yml
   ```

3. Set `lapcounter_app_image_tag` in `inventory/race_decoders.yml`
   ([how to pick one](docs/deploy_lapcounter_app.md#run-it)).
4. Run everything, over Ethernet:

   ```bash
   ansible-playbook -i inventory/race_decoders.yml site.yml -K
   ```

5. Check: `http://racedecoder.local/` from the wired side, or join the
   **RC Race Event** Wi-Fi and open `http://race/`. On the Pi,
   `journalctl -u openstint -f` shows decoder `S` lines every second.

On Ubuntu the `openstint_decoder` role builds OpenStint from a pinned upstream
commit (first run ~5-10 min on a Pi 4). Details:
[docs/provision_race_decoder.md](docs/provision_race_decoder.md#ubuntu-source-build).

## Roles

| Role | On the Pi |
|---|---|
| [`openstint_decoder`](roles/openstint_decoder/README.md) | `openstint` package (pinned apt repo or source build), `/etc/openstint.conf`, `openstint-learn`, optional ufw |
| [`race_network`](roles/race_network/README.md) | Hostname, `eth0` DHCP (default) or static; `eth0` is the only uplink |
| [`race_hotspot`](roles/race_hotspot/README.md) | `wlan0` access point (always), captive portal to `http://race`, NAT to `eth0` |
| [`race_dns`](roles/race_dns/README.md) | dnsmasq DHCP/DNS for the hotspot (pulled in by `race_hotspot`) |
| [`lapcounter_app`](roles/lapcounter_app/README.md) | Docker, `/opt/lapcounter/compose.yaml` (`web` :8080 + `lapd`) |

## What runs on a finished Pi

| Component | How | Port | Data |
|---|---|---|---|
| OpenStint decoder | `openstint.service` | ZeroMQ PUB :5556 | `/var/lib/openstint/*.rc4` |
| lapd | container `lapcounter-lapd-1` | reads :5556 | `/var/lib/lapcounter/lapcounter.db` |
| web | container `lapcounter-web-1` (gunicorn) | :8080 | same DB |
| Event hotspot | NetworkManager `race-hotspot`, `race-portal-firewall.service` | — | — |
| Captive portal | `race-portal.service` | :80 | serves the app at `http://race/` and `http://<pi>.local/` |
| DHCP/DNS | `dnsmasq` (race_dns) | 53, 67 on `wlan0` | |

## OpenStint

[OpenStint](https://github.com/zsellera/openstint) is a separate program by
its own authors under GPL-3.0. These playbooks install it from upstream; none
of its code is in this repo.

## Tests

```bash
python3 -m pip install --user pytest pyzmq ansible-core ansible-lint
python3 -m pytest roles -q
ansible-lint
ansible-playbook -i localhost, roles/race_network/tests/validate_localhost.yml
for p in provision_race_decoder configure_network deploy_lapcounter_app site; do
  ansible-playbook -i inventory/race_decoders.yml $p.yml --syntax-check; done
```

## License

Source-available under [FSL-1.1-ALv2](LICENSE) (each version becomes Apache-2.0
two years after its release). Plain-language summary: [LICENSING.md](LICENSING.md).
"RC Race HQ" is a trademark of Sturgeon Technologies LLC.
