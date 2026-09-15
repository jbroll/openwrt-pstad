# Quickstart

From a relayd-style repeater to one client with its own MAC upstream.

## Prerequisites

- An OpenWrt device joined upstream as an ordinary station: a `wifi-iface` in
  `mode 'sta'`, clients on `br-lan` through an AP or wired ports. `pstad` finds
  the backhaul as the interface named `*-staN` that netifd creates.
- A driver that allows several managed interfaces on one phy. Check
  "valid interface combinations" in `iw phy`. MT7915 under mt76 advertises
  `#{ managed } <= 19`, which leaves room for 18 clients.
- Root SSH access to the repeater.
- relayd removed, since it breaks proxied clients (see the
  [README](../README.md#why-not-relayd)):

  ```sh
  /etc/init.d/relayd disable
  /etc/init.d/relayd stop
  opkg remove relayd
  ```

  Also remove any relayd hotplug script, such as
  `/etc/hotplug.d/iface/99-relayd`.

## Install

```sh
sh install.sh repeater.local
```

This installs the needed packages, copies `pstad` and its init script, creates
an empty `/etc/psta/allow`, and starts the service.

## Allow a client

Nothing is proxied until `/etc/psta/allow` matches. Add one MAC per line:

```sh
echo 02:00:00:00:be:ef >> /etc/psta/allow
```

No restart is needed. A client already present is picked up at its next
association or by the next sweep, within a minute. A line containing only `*`
proxies every client.

## Verify

On the repeater, once the client has sent a frame or associated:

```sh
pstad status
```

```
02:00:00:00:be:ef psta-00beef on lan1, 412 pkts, seen Mon Sep 14 10:22:07 UTC 2026
```

`logread -e pstad` shows `up <mac> on <port> via <iface>`, or why setup failed.

On a host attached to the upstream access point, the client's address should
resolve to the client's own MAC:

```sh
ip neigh
```

```
192.0.2.57 dev wlan0 lladdr 02:00:00:00:be:ef REACHABLE
```

If it shows the repeater's station MAC instead, check the allowlist, that
relayd is gone, and `logread` for `did not associate`.
