# openwrt-pstad

A proxy-STA daemon for OpenWrt wireless repeaters. Each client behind the
repeater gets its own station on the backhaul radio, carrying the client's own
MAC address, so the upstream router sees the client itself rather than the
repeater. This is what MediaTek calls "MAC Repeater" and Broadcom calls "Proxy
STA", done in userspace on top of mainline `mac80211` and `mt76` with one
`wpa_supplicant` per client and a handful of `tc` flower redirect rules.

It is for anyone running an OpenWrt device as a wireless extender behind an
access point that will not accept 4-address (WDS) frames, most ISP routers
included, and who needs hosts behind the extender to keep their layer-2
identity: port forwards that resolve through the router's client table,
Wake-on-LAN, PXE, IPv6 neighbour discovery, and mDNS names that resolve from
anywhere on the LAN. relayd, OpenWrt's usual answer, hides every host behind
the repeater's one station MAC and loses all of those.

```sh
# On the repeater: proxy one client, then watch it come up.
echo 02:00:00:00:be:ef > /etc/psta/allow
/etc/init.d/pstad restart
pstad status
# 02:00:00:00:be:ef psta-00beef on lan1, 412 pkts, seen Mon Sep 14 10:22:07 UTC 2026
```

Install onto a repeater that already joins the upstream network as a plain
station (a relayd-style configuration) over SSH:

```sh
sh install.sh repeater.local
```

The `tc` flower redirect is the whole forwarding path, so the repeater needs
`tc-full kmod-sched-core kmod-sched-flower ip-bridge`; `install.sh` adds them.
relayd must not run alongside it.

- [docs/quickstart.md](docs/quickstart.md): from a relayd repeater to one
  proxied client.
- [docs/user-manual.md](docs/user-manual.md): commands, environment knobs, the
  allowlist, baking into an ImageBuilder overlay.
- [docs/architecture.md](docs/architecture.md): why a station cannot bridge,
  the option space, the per-phy station limit, and how the rules work.
- [docs/development.md](docs/development.md): layout and tests.
- [docs/backlog.md](docs/backlog.md): what is missing before `*` in the
  allowlist is safe on a busy repeater.

The companion repo `wr1800k-openwrt` (same author) builds and flashes a
credentialed OpenWrt image for the Fenvi WR1800K with this daemon baked in as
its `proxy` backhaul mode.

MIT licensed, see [LICENSE](LICENSE).
