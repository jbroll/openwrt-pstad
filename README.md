# openwrt-pstad

A proxy-STA daemon for OpenWrt wireless repeaters. Each client behind the
repeater gets its own station on the backhaul radio, carrying the client's own
MAC address, so the upstream router sees the client itself rather than the
repeater. This is what MediaTek calls "MAC Repeater" and Broadcom calls "Proxy
STA", done in userspace on top of mainline `mac80211` and `mt76` with one
`wpa_supplicant` per client and a handful of `tc` flower redirect rules.

It is for anyone running an OpenWrt device as a wireless extender behind an
access point that will not accept 4-address (WDS) frames, most ISP routers
included, and who needs hosts behind the extender to keep their own MAC
addresses upstream.

## Why not relayd

relayd is what OpenWrt offers for a repeater whose uplink is a station. It
keeps `br-lan` and the station unbridged, learns hosts on each side from ARP
and DHCP, installs a host route for each, and answers ARP for it on the other
side. DHCP is relayed so clients get upstream leases.

IP connectivity works, but every frame leaving the station carries the
station's MAC, so upstream every host behind the repeater has that one MAC:

- A router that resolves port-forward targets through its client table can
  deliver to the wrong host, since several addresses share one MAC.
- Wake-on-LAN from upstream never reaches the host.
- PXE, which identifies machines by MAC, fails.
- IPv6 neighbour discovery ties addresses to the wrong link-layer address.
- mDNS does not cross the boundary, so `.local` names resolve only for clients
  of the repeater's own AP.

With `pstad` each host has its own MAC upstream, and all of those work.

relayd and `pstad` cannot run together. Measured on one host within a minute:
relayd alone, 0% loss with the wrong MAC upstream; both, about 50% loss;
`pstad` alone, 0% loss. relayd re-announces the host's ARP under the station's
MAC, so the router learns two paths to the host and sends about half its
frames down the one with no redirect into the host's station. Remove relayd,
including any hotplug script that starts it, before enabling `pstad`.

## Example

```sh
# On the repeater: proxy every client, then watch one come up.
echo '*' > /etc/psta/allow
/etc/init.d/pstad restart
pstad status
# 02:00:00:00:be:ef psta-00beef on lan1, 412 pkts, seen Mon Sep 14 10:22:07 UTC 2026
```

## Install

On a repeater already joined upstream as a plain station, from a checkout:

```sh
sh install.sh repeater.local
```

It installs `tc-full kmod-sched-core kmod-sched-flower ip-bridge tcpdump-mini`
if missing, then the daemon and its init script.

## Documentation

- [docs/quickstart.md](docs/quickstart.md): from a relayd repeater to one
  proxied client.
- [docs/user-manual.md](docs/user-manual.md): commands, environment knobs, the
  allowlist, baking into an ImageBuilder overlay.
- [docs/architecture.md](docs/architecture.md): why a station cannot bridge,
  the processes and events, and the rule set.
- [docs/development.md](docs/development.md): layout and tests.
- [docs/backlog.md](docs/backlog.md): open work.

The companion repo [wr1800k-openwrt](https://github.com/jbroll/wr1800k-openwrt) builds and flashes a
credentialed OpenWrt image for the Fenvi WR1800K with this daemon baked in as
its `proxy` backhaul mode.

MIT licensed, see [LICENSE](LICENSE).
