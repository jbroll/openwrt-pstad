# Quickstart

From a working relayd-style repeater to one client with its own MAC upstream.

## Prerequisites

- An OpenWrt device already joined to the upstream network as an ordinary
  3-address station, with its clients on `br-lan`. This is the layout relayd
  uses: a `wifi-iface` in `mode 'sta'` on one radio, an AP on the other or
  wired ports in the bridge, and `br-lan` carrying no address of its own.
  `pstad` finds the backhaul by looking for an interface named `*-staN`, which
  is what netifd creates for that station.
- A driver whose phy allows more than one managed interface at a time.
  `iw phy` lists this under "valid interface combinations"; mt76 on MT7915
  advertises `#{ managed } <= 19`. See
  [architecture.md](architecture.md) for the measurement.
- Packages `tc-full kmod-sched-core kmod-sched-flower ip-bridge`, and
  `tcpdump-mini` for the monitor interface that hears clients roaming away.
  `install.sh` installs the first set if `tc-full` is missing and
  `tcpdump-mini` if no `tcpdump` is present.
- SSH access as root from the machine you install from.
- relayd removed. It re-issues each host's ARP under the station's own MAC and
  gives the upstream a second delivery path for every proxied host; measured at
  about 50% packet loss when both run. Disable it before starting `pstad`:

  ```sh
  /etc/init.d/relayd disable; /etc/init.d/relayd stop
  opkg remove relayd
  ```

  An image built with a relayd hotplug script (for example a
  `/etc/hotplug.d/iface/99-relayd`) needs that removed too.

## Install

```sh
sh install.sh repeater.local
```

This installs the packages, loads `act_mirred` and `cls_flower` to confirm the
kernel can do the redirect, copies `pstad` to `/usr/sbin/pstad` and
`pstad.init` to `/etc/init.d/pstad`, creates an empty `/etc/psta/allow`,
enables the service and restarts it.

## Allow a client

`/etc/psta/allow` lists one MAC per line. Nothing is proxied until a line
matches. Add the client and restart:

```sh
echo 02:00:00:00:be:ef >> /etc/psta/allow
/etc/init.d/pstad restart
```

A lone `*` line proxies every client. Read [backlog.md](backlog.md) before
using it on a repeater with more than a few clients or any that roam.

## Verify

On the repeater, once the client has sent a frame through the bridge:

```sh
pstad status
```

```
02:00:00:00:be:ef psta-00beef on lan1, 412 pkts, seen Mon Sep 14 10:22:07 UTC 2026
```

The packet count is the client's upstream redirect counter and rises as the
client talks. `logread -e pstad` shows `up <mac> on <port> via <iface>` on
setup and any failure reason.

On a host attached to the upstream access point, the client's address should
now resolve to the client's own MAC rather than the repeater's station:

```sh
ip neigh
```

```
192.0.2.57 dev wlan0 lladdr 02:00:00:00:be:ef REACHABLE
```

If it still shows the repeater's station MAC, the client has not been proxied:
check the allowlist, that relayd is gone, and `logread` for `did not associate`.
