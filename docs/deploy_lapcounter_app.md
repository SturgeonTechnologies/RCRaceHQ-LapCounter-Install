# deploy_lapcounter_app

Installs Docker on a race-decoder Pi and runs the lap counter app (`lapd` +
`web`) from the image that
[RCRaceHQ-LapCounter-App](https://github.com/SturgeonTechnologies/RCRaceHQ-LapCounter-App)'s
CI builds and pushes to GHCR. Role:
[`lapcounter_app`](../roles/lapcounter_app/README.md).

## How the pieces fit

```
RCRaceHQ-LapCounter-App (app code)        RCRaceHQ-LapCounter-Install (this repo)
  push to main / tag vX.Y.Z                 inventory: lapcounter_app_image_tag
        │                                          │
        ▼                                          ▼
  GitHub Actions: test, native arm64  ──►  ghcr.io/sturgeontechnologies/
  build, push :sha-<7> (and :vX.Y.Z)        rcracehq-lapcounter (public) 
                                                   │  docker pull (no login)
                                                   ▼
                                          Pi: /opt/lapcounter/compose.yaml
                                              web  :8080 ─┐
                                              lapd ───────┴─ /var/lib/lapcounter/lapcounter.db
                                                │
                                                └─ tcp://127.0.0.1:5556  (openstint.service)
```

The app code never lives here. This repo only decides **which tag** each Pi
runs and **how** it's run.

## What it does

On the target Pi (`become: true`):

1. Checks it's arm64 on Debian 13+ (Trixie) or Ubuntu 24.04+, that
   `lapcounter_app_image_tag` is set (and isn't `latest`), and that the
   registry username + token are set.
2. Adds Docker's apt repo for the host's distribution (`linux/debian` or
   `linux/ubuntu`; deb822, `Signed-By`). The key is downloaded, its
   fingerprint is checked against `9DC85822…0EBFCD88`, and only then installed.
   Installs `docker-ce`, `docker-ce-cli`, `containerd.io`,
   `docker-compose-plugin`.
3. Writes `/etc/docker/daemon.json`: `local` log driver, 10 MB × 3 files per
   container.
4. Writes the token to root's `/root/.docker/config.json` (0600) for
   `ghcr.io`. The task is `no_log` and skips `--diff`.
5. Creates `/var/lib/lapcounter` (uid 10001, the image's user), checks the
   decoder's `.rc4` folder (`/var/lib/openstint`) exists and is
   group-writable, and renders `/opt/lapcounter/compose.yaml`. `web` gets that
   folder mounted read-write plus its group, for transponder learning (below).
6. `docker compose up` (project `lapcounter`), pulling the image only if it
   isn't on the Pi yet. CI never re-pushes a tag, so once a tag is on the Pi it
   never needs the internet again; the containers come back after a reboot on
   their own (`restart: unless-stopped`).
7. Waits for `http://127.0.0.1:8080/healthz` and prints where to look.

## Transponder learning

Learning is done in the app: **Admin → Transponders** (`http://<pi>:8080/transponders`).
Type the number on the label, set the transponder still on the loop or pad,
wait for **Record**, press it. The app renames OpenStint's auto-numbered
`<1000-9999>.rc4` to `<label>.rc4` in `/var/lib/openstint`, so the `web`
container needs that folder:

- mounted read-write at the same path (`OPENSTINT_RC4_DIR`), and
- the folder's group in `group_add` (read from the Pi with `stat`; `users`,
  gid 100, from the openstint package's `root:users 2775`).

User guide and how it works:
[RCRaceHQ-LapCounter-App docs/learning.md](https://github.com/SturgeonTechnologies/RCRaceHQ-LapCounter-App/blob/main/docs/learning.md).
`openstint-learn` on the Pi (from `openstint_decoder`) still works as a
fallback over SSH.

Check the mount on the Pi:

```bash
cd /opt/lapcounter
sudo docker compose exec web id                 # groups include 100(users)
sudo docker compose exec web ls -ld /var/lib/openstint
```

## Linking to RC Race HQ

**Settings → Link to RC Race HQ** (`http://<pi>:8080/settings`) pairs the Pi
with one track of a club: it shows a code, a club manager types it under
**Manage → club → Lap counters** in RC Race HQ, and the Pi stores its new IoT
certificate. The role only has to tell the app where the API is:

```yaml
lapcounter_app_rcracehq_api_url: "https://www.rcracehq.com/api"   # the default
```

It defaults to RC Race HQ, so you only set it to point a Pi somewhere else. The key and
certificate live in the app's data volume (`/var/lib/lapcounter/cloud/`, 0700),
so they survive redeploys and image upgrades. Check it on the Pi:

```bash
cd /opt/lapcounter && sudo docker compose exec web sh -c 'env | grep RCRACEHQ; ls -la /var/lib/lapcounter/cloud'
```

User guide, what's stored and error messages: the app repo's
[docs/linking.md](https://github.com/SturgeonTechnologies/RCRaceHQ-LapCounter-App/blob/main/docs/linking.md).

## Image access

The image is a public GHCR package, so the Pi pulls it without logging in
(`lapcounter_app_registry_auth: none`, the default). If you mirror it to a
private registry, set `lapcounter_app_registry_auth: token` and put
`lapcounter_app_registry_username` / `lapcounter_app_registry_token` in an
ansible-vault file (for example `inventory/group_vars/race_decoders/vault.yml`),
then add `--ask-vault-pass` to the commands below.

## Run it

Pick a tag CI pushed:

```bash
# Releases list the tags: https://github.com/SturgeonTechnologies/RCRaceHQ-LapCounter-App/releases
# Or browse https://github.com/orgs/SturgeonTechnologies/packages/container/package/rcracehq-lapcounter
```

Set it in `inventory/race_decoders.yml` (`lapcounter_app_image_tag:
sha-1a2b3c4` or `v0.1.0`), then from the repo root:

```bash
ansible-playbook -i inventory/race_decoders.yml deploy_lapcounter_app.yml --syntax-check
ansible-playbook -i inventory/race_decoders.yml deploy_lapcounter_app.yml
```

One Pi, or try a tag without committing it:

```bash
ansible-playbook -i inventory/race_decoders.yml deploy_lapcounter_app.yml \
  --limit racedecoder -e lapcounter_app_image_tag=sha-1a2b3c4
```

`--check` works once Docker is installed (the first run has no
`docker.service` to look at yet).

Then open `http://racedecoder.local:8080/`. The first visit goes to **Set up
the lap counter**.

## Upgrade and roll back

Both are the same thing: change `lapcounter_app_image_tag` and run the
playbook. Compose recreates the two containers on the new image; the SQLite
database in `/var/lib/lapcounter` is kept. Old images stay on the Pi, so
rolling back to the previous tag doesn't need the internet.

Do it before race day, not during: there's a few seconds without `lapd` while
the containers swap.

Free SD space now and then: `sudo docker image prune -a` (removes every image
not used by a running container, including the one you'd roll back to).

## On the Pi

```bash
cd /opt/lapcounter
sudo docker compose ps                 # web should be "healthy"
sudo docker compose logs -f lapd web
sudo docker compose restart lapd
sudo sqlite3 /var/lib/lapcounter/lapcounter.db '.tables'   # apt install sqlite3
```

## Variables

| Var | Default | Notes |
| --- | --- | --- |
| `lapcounter_app_image_tag` | `""` | **Required.** `sha-<7>` or `vX.Y.Z`; `latest` is refused |
| `lapcounter_app_registry` | `ghcr.io` | |
| `lapcounter_app_image_repository` | `<registry>/sturgeontechnologies/rcracehq-lapcounter` | |
| `lapcounter_app_registry_auth` | `none` | `token` for a private mirror |
| `lapcounter_app_registry_username` | `""` | Only with `token`. Registry user |
| `lapcounter_app_registry_token` | `""` | Only with `token`. Vault it |
| `lapcounter_app_install_docker` | `true` | `false` = Docker is already there, skip apt |
| `lapcounter_app_dir` | `/opt/lapcounter` | compose project folder |
| `lapcounter_app_data_dir` | `/var/lib/lapcounter` | SQLite; owned by uid 10001 |
| `lapcounter_app_web_port` | `8080` | Health check, and where the hotspot portal sends people (`race_hotspot_app_port`). The image binds 8080 |
| `lapcounter_app_decoder_zmq` | `tcp://127.0.0.1:<openstint_decoder_zmq_port>` | lapd's `OPENSTINT_ZMQ` |
| `lapcounter_app_decoder_stale_s` | `5` | `LAPCOUNTER_DECODER_STALE_S` |
| `lapcounter_app_rc4_dir` | `<openstint_decoder_registry_dir>` (`/var/lib/openstint`) | Mounted rw into `web` as `OPENSTINT_RC4_DIR`; `web` joins the folder's group so Transponders → Record can rename learned files. Must exist and be group-writable (the role checks) |
| `lapcounter_app_rcracehq_api_url` | `https://www.rcracehq.com/api` | RC Race HQ API base URL, passed as `RCRACEHQ_API_URL`. Empty turns Settings → Link off. See the app repo's [docs/linking.md](https://github.com/SturgeonTechnologies/RCRaceHQ-LapCounter-App/blob/main/docs/linking.md) |
| `lapcounter_app_docker_log_max_size` / `_max_file` | `10m` / `3` | |
| `lapcounter_app_wait_timeout` | `180` | seconds for compose to report healthy |

## Not done yet

- **ufw on the wired side.** The app stays on :8080. With
  `openstint_decoder_manage_ufw: true`, `race_hotspot` opens :8080 on the
  hotspot and (with `race_hotspot_web_on_eth0`, the default) on `eth0`; this
  role doesn't open it by itself.
- **AWX.** The layout works as an AWX project as is (root `ansible.cfg`,
  `collections/requirements.yml`). Templates still need an inventory source
  (and a vault credential if you use a private mirror).
