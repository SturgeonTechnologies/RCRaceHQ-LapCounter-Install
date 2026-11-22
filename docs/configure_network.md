# configure_network

How the lap counter Pi is networked, and how to change it.

```
 track LAN / router ── eth0 (required) ──┐
   internet, RC Race HQ sync,            │   Pi
   race control: http://<pi>.local/      │   app on :8080
                                         │
 phones / pit TVs ─── wlan0 hotspot ─────┘   (always, built-in radio)
   "RC Race Event" → captive portal → same app page
```

- **Wired (`eth0`) is required.** It's the Pi's only internet connection
  (RC Race HQ sync, image pulls, updates) and where race control runs the
  event from a laptop. DHCP by default, static if you set one.
- **Wi-Fi is the built-in radio, and it's only the event hotspot.** Every
  provisioned kit brings it up. Spectators and racers join it, the captive
  portal lets them out to the internet through `eth0`, and sends them to the
  same app page the wired side sees (live/race status, check-in, kiosk). The
  Pi never joins someone else's Wi-Fi.

Two roles, run in this order by both `configure_network.yml` and
`provision_race_decoder.yml`:

| Role | Sets |
|---|---|
| [`race_network`](../roles/race_network/README.md) | Hostname, `eth0` DHCP/static |
| [`race_hotspot`](../roles/race_hotspot/README.md) (+ `race_dns`) | Wi-Fi details: SSID, passphrase, channel, country; captive portal; NAT out `eth0`. Always applied. |

## Run it

```bash
ansible-playbook -i inventory/race_decoders.yml configure_network.yml --syntax-check
ansible-playbook -i inventory/race_decoders.yml configure_network.yml \
  --limit racedecoder -k -K
```

Add `--ask-vault-pass` once the hotspot passphrase is in the vault.
Run it over Ethernet: the hotspot role refuses to run if your SSH session is
on `wlan0`.

## Wired port

| `race_network_ethernet_mode` | What |
|---|---|
| `dhcp` (default) | Address from the track's router. DNS servers optional. |
| `static` | Fixed address. Needs `race_network_ethernet_address` (CIDR) and `race_network_ethernet_gateway`. |
| `unmanaged` | Leave `eth0` as the OS set it up. Switching to this removes the role's config. |

```yaml
race_network_ethernet_mode: static
race_network_ethernet_address: 192.168.1.50/24
race_network_ethernet_gateway: 192.168.1.1
race_network_ethernet_dns: [192.168.1.1, 1.1.1.1]
```

How it's applied:

- **Raspberry Pi OS:** a NetworkManager profile `race-eth0` with priority 100,
  so it wins over the `Wired connection 1` profile from first boot.
- **Ubuntu:** `/etc/netplan/60-race-network.yaml` (mode 0600), merged over
  `50-cloud-init.yaml`. The file is checked with `netplan generate` before it
  is installed, so a bad file never lands.
- The change is applied in the background (`nmcli connection up` /
  `netplan apply`), then Ansible reconnects. `eth0` blinks for a few seconds.
  The first run on an existing Pi does this once, as the role takes over
  `eth0` on DHCP; the router normally hands back the same address.
- **If the address changes** (static), the SSH session can't follow. The role
  prints the new address and stops that host's run. Set `ansible_host` to the
  new address in the inventory and rerun to finish.
- At the end it checks the default route is on `eth0` and warns if it isn't
  (cable out, no DHCP, wrong gateway).

**Getting back in if a static address is wrong:** SSH is closed on the event
hotspot on purpose, so use a screen and keyboard, or put the SD card in
another machine and delete `/etc/netplan/60-race-network.yaml` (Ubuntu) or
`/etc/NetworkManager/system-connections/race-eth0.nmconnection` (Pi OS).
Double-check the address before you run it.

## Wi-Fi (event hotspot)

All in the inventory, passphrase in the vault:

```yaml
# inventory/race_decoders.yml
race_hotspot_ssid: "Riley's Place Race"
race_hotspot_channel: 6           # 2.4 GHz; pick a quiet one at the track
race_hotspot_country: US
```

```bash
EDITOR=vim ansible-vault edit inventory/group_vars/race_decoders/vault.yml
```
```yaml
race_hotspot_passphrase: "at least 8 chars"   # leave unset for an open network
```

What a phone sees:

1. Joins the SSID and gets a `10.77.0.x` address from the Pi.
2. The phone's "sign in to network" sheet opens `http://race/`.
3. The portal lets that phone out to the internet through `eth0` for 12 h
   and serves the lap counter app right there at **`http://race/`** (it
   proxies the app on port 80, so nobody has to type a port). That's the same
   app race control has open on the wired side.
4. If the app isn't running yet (not deployed, restarting), the portal shows
   a short "isn't running yet" page instead of a dead link.

From there:

| Who | URL | What |
|---|---|---|
| Spectator / pit TV | `http://race/` | Live race status (current heat, running order) |
| Racer's phone | `http://race/checkin` | Walk-up check-in (phone number → checklist → Ready to race!) |
| Desk tablet | `http://race/kiosk` | Same check-in, no menu, 45s idle reset |
| Race control | `http://<hostname>.local/` on `eth0` | Manage (SSH stays closed on the open AP) |

The live page has **Racing today? Check in here**. Bookmark `/kiosk` on the
desk tablet. Admin still needs the local login.

On the wired side, `http://<hostname>.local/` serves the app the same way.
With `install.sh` the app only listens on `127.0.0.1:8080`, so port 80 is the only way in.

What hotspot devices can reach on the Pi: DHCP, DNS and the portal (:80),
which serves the app. The app's own port (`race_hotspot_app_port`), SSH and
the decoder feed stay closed on the hotspot.

The portal passes each phone's address to the app in `X-Forwarded-For`
(dropping any the phone sent), and the app trusts it only from 127.0.0.1, so
the check-in throttle still works per phone. That needs the LapCounter image
with `TrustLocalProxy` (LapCounter #25).

The playbook always brings the AP up. `race_hotspot_enabled: false` is
refused. To tear it down on a Pi by hand (the next run puts it back):
`sudo nmcli connection delete race-hotspot && sudo systemctl disable --now race-portal race-portal-firewall`.

## Hostname

```yaml
race_network_hostname: rcclub-track1
```

Lowercase letters, digits and dashes. The role sets it with systemd, points
`127.0.1.1` at it in `/etc/hosts`, and on Ubuntu tells cloud-init not to put
the image's name back on reboot. It's also the wired address race control
uses: `http://rcclub-track1.local/`. If you were reaching the Pi as
`racedecoder.local`, update `ansible_host` afterwards.

## Variables

| Var | Default | Notes |
|---|---|---|
| `race_network_hostname` | `""` | empty = leave it |
| `race_network_ethernet_interface` | `eth0` | can't be the hotspot radio |
| `race_network_ethernet_mode` | `dhcp` | `dhcp`, `static`, `unmanaged` |
| `race_network_ethernet_address` | `""` | CIDR, static only |
| `race_network_ethernet_gateway` | `""` | static only |
| `race_network_ethernet_dns` | `[]` | IPv4 addresses |
| `race_network_ethernet_metric` | `100` | |
| `race_hotspot_ssid` / `_passphrase` | `RC Race Event` / open | passphrase 8-63 chars, vault it |
| `race_hotspot_channel` / `_band` / `_country` | `6` / `bg` / `US` | |
| `race_hotspot_app_port` | `lapcounter_app_web_port` or `8080` | app the portal proxies on :80; `0` = portal page only |
| `race_hotspot_web_on_eth0` | `true` | `http://<hostname>.local/` serves the app on the wired side |

Full hotspot vars: [race_hotspot README](../roles/race_hotspot/README.md#vars).

`race_network_wifi` (client Wi-Fi on a USB dongle, PR #12) was removed. If
it's still set, the role stops and asks you to delete it, and any
`race-wifi-*` profiles it made are removed on the next run.

## Check it on the Pi

```bash
ip -4 route                         # default via ... dev eth0
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status
nmcli connection show --active      # race-hotspot on wlan0
curl -s http://127.0.0.1/healthz -H 'Host: racedecoder.local'   # → {"ok": true, ...} from the app
cat /etc/netplan/60-race-network.yaml   # Ubuntu
```

## Tests

```bash
ansible-playbook -i localhost, roles/race_network/tests/validate_localhost.yml
python3 -m pytest roles/race_hotspot/tests -q
```

The first runs only `race_network`'s validation on localhost: the defaults and
a static config must pass, and each bad case (client Wi-Fi set, `eth0` set to
the hotspot radio, static without CIDR or gateway, unknown mode, non-IP DNS,
bad hostname) must fail. The second covers the portal, including the hand-off
to the app. CI runs both in the `lint-test` job.
