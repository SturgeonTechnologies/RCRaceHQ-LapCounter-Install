# lapcounter_app

Runs the lap counter app from
[RCRaceHQ-LapCounter-App](https://github.com/SturgeonTechnologies/RCRaceHQ-LapCounter-App)
on the race-decoder Pi:

- Docker Engine + compose plugin from Docker's apt repo (`linux/debian` or
  `linux/ubuntu`, picked from the host's distribution; same signing key). The repo key is only
  installed if its fingerprint matches `lapcounter_app_docker_gpg_fingerprint`.
- `/etc/docker/daemon.json`: `local` log driver with rotation (SD card).
- GHCR login: a read-only token (`read:packages`) written to root's
  `/root/.docker/config.json` (0600). Not logged, not shown in `--diff`.
- `/opt/lapcounter/compose.yaml` with the pinned image, services `web` and
  `lapd`, host networking, data bind-mounted from `/var/lib/lapcounter`.
- `web` also gets the decoder's `.rc4` folder (`/var/lib/openstint`) read-write
  and joins its group, so Admin → Transponders → Record can rename learned
  files. The role refuses to continue if that folder is missing or not
  group-writable (run `provision_race_decoder.yml` first).
- `web` gets `RCRACEHQ_API_URL` from `lapcounter_app_rcracehq_api_url` for
  Settings → Link (pairing with a track in RC Race HQ). Empty turns Link off.
- `docker compose up` with `pull: missing`, waits for healthy, then checks
  `http://127.0.0.1:8080/healthz`.

Usage, variables, upgrades and rollback:
[`docs/deploy_lapcounter_app.md`](../../docs/deploy_lapcounter_app.md).
Defaults with comments: [`defaults/main.yml`](defaults/main.yml).

## Requirements

- Ansible >= 2.15, `community.docker` (`docker_compose_v2`; needs only the
  Docker CLI on the target, no Python Docker SDK)
- Target: arm64 Debian 13+ (Raspberry Pi OS Trixie) or Ubuntu 24.04+
- `lapcounter_app_registry_username` + `lapcounter_app_registry_token`
  (vaulted), see the doc above. No AWS / SSM needed.
