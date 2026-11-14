# race_network

The lap counter Pi's own network: hostname and the wired port. `eth0` is the
Pi's only uplink (internet, RC Race HQ sync) and where race control uses the
app.

- **Wired port**: `dhcp` (default), `static` or `unmanaged`. NetworkManager
  profile `race-eth0` on Raspberry Pi OS, `/etc/netplan/60-race-network.yaml`
  on Ubuntu. Warns at the end if the default route isn't on `eth0`.
- **Hostname**: systemd hostname, `127.0.1.1` in `/etc/hosts`, and
  `preserve_hostname: true` for cloud-init on Ubuntu.

Wi-Fi isn't here: the built-in radio is only the event hotspot, configured by
[race_hotspot](../race_hotspot/README.md) (`race_hotspot_ssid`,
`race_hotspot_passphrase`, ...). The Pi never joins a Wi-Fi network as a
client.

Full usage and recovery: [docs/configure_network.md](../../docs/configure_network.md).

## Safety

- Refuses `eth0` settings on the hotspot radio, and refuses the removed
  `race_network_wifi` setting with a message saying where Wi-Fi went.
  Deletes any `race-wifi-*` profiles left from that setting.
- Netplan files are checked with `netplan generate` before they're installed.
- The wired change runs last, applied in the background. If the address
  changes, the role prints the new one and ends that host's run instead of
  hanging on a dead SSH session.

## Tests

`tests/validate_localhost.yml` runs `tasks/validate.yml` on localhost: the
defaults and a static config pass, seven bad cases fail.
