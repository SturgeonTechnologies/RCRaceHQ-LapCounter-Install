# race_dns

dnsmasq as DHCP + DNS for one LAN interface on the lap counter Pi.

- Leases `race_dns_dhcp_start`–`race_dns_dhcp_end` on `race_dns_interface`, with
  the Pi as router and DNS server.
- Answers `race` and `race.lan` with the Pi's address, so `http://race` is the
  event web UI. Everything else is forwarded to the Pi's upstream resolvers.
- Only binds the event interface (never `lo` or the uplink), so it can't hand
  out leases onto a track's network.

Used by `race_hotspot` (which passes its interface and addressing in), but it
works on its own for any LAN interface, e.g. a wired event switch on `eth1`.

| Var | Default | |
|---|---|---|
| `race_dns_interface` | `wlan0` | LAN to serve |
| `race_dns_address` | `10.77.0.1` | Pi's address on it |
| `race_dns_netmask` | `255.255.255.0` | |
| `race_dns_dhcp_start` / `_end` | `.50` / `.250` | lease pool |
| `race_dns_lease_time` | `12h` | |
| `race_dns_hostname` | `race` | the name people type |
| `race_dns_domain` | `lan` | local domain + search domain |
