# race_hotspot

Event Wi-Fi on the lap counter Pi's built-in radio (always on for a
provisioned kit), with a captive portal that hands devices to the lap counter
app. This is the only Wi-Fi the kit uses; the Pi's own internet is `eth0`
([race_network](../race_network/README.md)).

1. The built-in radio (`wlan0`) runs an access point, open `RC Race Event` by
   default. DHCP and DNS come from **race_dns** (pulled in by `meta/main.yml`).
2. A new device's plain-HTTP requests are redirected to `http://race/`. That is
   what makes phones and laptops pop the "sign in to network" sheet. HTTPS and
   everything else is refused (fast reset) until then.
3. Opening `http://race/` adds the device to the nftables set `allowed` for
   `race_hotspot_access_timeout` (12 h). From then on it gets internet through
   `eth0`, NATed.
4. The portal serves the app right there: it proxies `http://race/` to
   `127.0.0.1:<app port>` (`race_hotspot_app_port`, follows
   `lapcounter_app_web_port`, 8080), so the address is `http://race/`,
   `http://race/checkin`, `http://race/kiosk`, with no port. It's the same app
   the wired side uses. If nothing answers on that port yet, it shows its own
   short "isn't running yet" page instead. The phone's address goes to the app
   in `X-Forwarded-For` (any the phone sent is dropped); the app trusts it
   only from 127.0.0.1.

The open Wi-Fi can only reach DHCP, DNS and the portal (:80) on the Pi. The
app's own port is closed there; it's reached through the portal. SSH and the decoder's ZeroMQ feed stay closed to it.

## Wired side (`race_hotspot_web_on_eth0`)

On by default, for race control's laptop at the timing table or a TV in the
pits:

- The web server listens on every interface, not only `10.77.0.1`.
- avahi publishes it as **`http://<pi hostname>.local/`** (e.g.
  `http://racedecoder.local/`). A bare `race` only resolves on the hotspot,
  because we don't control the track router's DNS.
- Clients that aren't on the hotspot subnet get the app proxied the same way
  (`http://racedecoder.local/`). No internet grant; they aren't routed through
  the Pi. `:8080` still answers on `eth0` too.
- With ufw on, port 80, the app port and mDNS are allowed in on `eth0` from
  `race_hotspot_web_eth0_allowed_cidr` (`any` by default, since the track LAN isn't
  known when you provision; set a CIDR to narrow it). Setting
  `race_hotspot_web_on_eth0: false` again removes those rules and the mDNS record.

## Pieces

| File on the Pi | What |
|---|---|
| NetworkManager profile `race-hotspot` | AP on `wlan0`, static `10.77.0.1/24`, IPv6 off |
| `/etc/race/race-portal.nft` + `race-portal-firewall.service` | Own `inet race_portal` table: portal redirect, input lockdown, forward + NAT. Never flushes other tables (ufw is left alone). |
| `/usr/local/sbin/race-portal` + `race-portal.service` | Stdlib Python HTTP server on `10.77.0.1:80` (all interfaces with `race_hotspot_web_on_eth0`). Unprivileged (`DynamicUser`) with only `CAP_NET_ADMIN` + `CAP_NET_BIND_SERVICE`. |
| `/etc/sysctl.d/90-race-hotspot.conf` | `net.ipv4.ip_forward = 1` |
| `/etc/avahi/services/race-web.service` | Only with `race_hotspot_web_on_eth0`: mDNS `_http._tcp` record for the page |


## Safety

- The role refuses to run if the Pi's default route is on the hotspot
  interface (you'd lose SSH and the uplink). Provision over Ethernet.
- It sets the Wi-Fi country because Raspberry Pi OS keeps the radio blocked
  until one is set. With `raspi-config` (Pi OS) it uses that; without it
  (Ubuntu) it writes `/etc/modprobe.d/race-hotspot-regdom.conf`, runs
  `iw reg set`, and `rfkill unblock wifi`.
- It needs NetworkManager for the access point. Raspberry Pi OS has it. On
  Ubuntu the role installs `network-manager` and leaves netplan alone:
  Ubuntu's package only manages Wi-Fi devices by default, so `eth0` stays on
  systemd-networkd and SSH isn't interrupted. It stops if netplan already
  configures the hotspot interface under `wifis:`; remove that block and
  `sudo netplan apply` first.
- If `openstint_decoder_manage_ufw` is on, it adds the ufw allow and route rules
  the hotspot needs.

## Vars

| Var | Default | |
|---|---|---|
| `race_hotspot_ssid` | `RC Race Event` | |
| `race_hotspot_passphrase` | `""` (open) | 8–63 chars for WPA2; vault it |
| `race_hotspot_uplinks` | `[eth0]` | the Pi's only uplink |
| `race_hotspot_app_port` | `lapcounter_app_web_port` or `8080` | app the portal proxies on :80 (not opened on the hotspot); `0` = portal page only |
| `race_hotspot_access_timeout` | `12h` | also the DHCP lease time |
| `race_hotspot_country` | `US` | |
| `race_hotspot_band` / `_channel` | `bg` / `6` | |
| `race_hotspot_address` / `_prefix` / `_netmask` | `10.77.0.1` / `24` / `255.255.255.0` | keep the three consistent |
| `race_hotspot_hostname` / `_domain` | `race` / `lan` | |
| `race_hotspot_web_on_eth0` | `true` | `http://<hostname>.local/` → app on the wired side |
| `race_hotspot_web_eth0_interface` | `eth0` | |
| `race_hotspot_web_eth0_allowed_cidr` | `any` | ufw source for the wired page |

The playbook always applies this role. `race_hotspot_enabled: false` is
refused. To tear the AP down on a Pi by hand (the next playbook run puts it
back):
`sudo nmcli connection delete race-hotspot && sudo systemctl disable --now race-portal race-portal-firewall`.

## Checks

```
nmcli connection show --active            # race-hotspot on wlan0
sudo nft list set inet race_portal allowed # who's been let through
journalctl -u race-portal -f               # "allowed 10.77.0.x for 12h"
```
Tests: `python3 -m pytest roles/race_hotspot/tests -q`
