# User manual

## Commands

`pstad` takes one subcommand. The init script runs `monitor` and `sweep` and
calls `teardown-all` on stop. [architecture.md](architecture.md) describes how
they work together.

### `pstad monitor`

Waits until the backhaul is associated, writes the shared supplicant config,
sets up allowlisted clients already in `br-lan`'s fdb, then reacts to events:

- A client learned on a bridge port, or associating to the repeater's AP, is
  set up. A known client seen on a different port is rebuilt there.
- A client that leaves the repeater's AP and does not come back within
  `PSTA_LEAVE_WAIT` seconds is torn down and held off for `PSTA_HOLDOFF`
  seconds.
- A proxy station dropped by the upstream AP is left to reconnect if its
  client is wired or was heard within `PSTA_RECENT` seconds, and torn down
  otherwise.
- A proxied wireless client heard associating to the upstream BSS through
  another radio is torn down after `PSTA_JOIN_DELAY` seconds, removed from the
  repeater's AP, and held off. This needs `tcpdump` and uses a monitor
  interface named by `PSTA_MONIF`.

On TERM or INT it stops its children and deletes the monitor interface.

### `pstad sweep`

Every `PSTA_SWEEP` seconds:

- rebuilds every station if the backhaul's BSSID has changed;
- tears down a client whose station has more than one `wpa_supplicant`, has
  been disconnected for `PSTA_DOWN_GRACE` seconds, or has carried no frames
  from the client for `PSTA_IDLE` seconds;
- kills `wpa_supplicant` processes on `psta-*` stations no client owns;
- moves the group-frame rule to a connected station if needed;
- sets up any allowlisted client in the fdb that has no station.

### `pstad teardown-all`

Removes every station, rule, `clsact` qdisc `pstad` added, supplicant and the
supplicant config. Safe with no clients present.

### `pstad status`

One line per client:

```
<mac> <iface> on <port>, <count> pkts, seen <date>[, forwards group frames]
```

`count` is the redirect counter as of the last sweep, so it lags by up to
`PSTA_SWEEP` seconds. One line carries `forwards group frames` while any client
is up.

## Environment

Read at start. Set them in the init script's instances, or on the command line
for a manual run.

| Variable | Default | Meaning |
|---|---|---|
| `RUN` | `/var/run/psta` | State directory |
| `ALLOW` | `/etc/psta/allow` | Allowlist path |
| `PSTA_BRIDGE` | `br-lan` | Bridge whose ports carry clients |
| `PSTA_SWEEP` | `60` | Seconds between sweeps |
| `PSTA_IDLE` | `300` | Seconds with no frames from a client before it is torn down |
| `PSTA_ASSOC` | `20` | Seconds a new station may take to associate |
| `PSTA_DOWN_GRACE` | `120` | Seconds a station may stay disconnected |
| `PSTA_LEAVE_WAIT` | `3` | Seconds a client may take to reappear on the AP, which covers a reassociation. The monitor handles no other event meanwhile |
| `PSTA_HOLDOFF` | `60` | Seconds a departed client is not set up again from stale frames. Cleared when the AP reports it back |
| `PSTA_RECENT` | `10` | Seconds within which a wireless client must have been heard for its dropped station to be kept |
| `PSTA_JOIN_DELAY` | `1` | Seconds between hearing a client join elsewhere and tearing down its station |
| `PSTA_MONIF` | `pstamon` | Name of the monitor interface on the backhaul phy |

## The allowlist

`/etc/psta/allow` has one entry per line:

- a MAC address in colon form, any case, proxies that client;
- a line containing only `*` proxies every client.

A missing or empty file proxies nothing. The file is read on every event, so
new entries take effect without a restart. A client removed from the list
stays up until it idles out or the service restarts.

Use `*` on a deployed repeater and a MAC list on a bench. The phy's station
limit still applies: on MT7915 the 19th client's station cannot come up, and
that client has no upstream path. See [backlog.md](backlog.md).

## install.sh

```sh
sh install.sh <repeater-host>
```

Over SSH as `root@<repeater-host>` it:

1. installs `tc-full kmod-sched-core kmod-sched-flower ip-bridge` unless
   `tc-full` is present, and `tcpdump-mini` unless some `tcpdump` is;
2. loads `act_mirred` and `cls_flower`, which the redirect rules need;
3. copies `pstad` to `/usr/sbin/pstad` and `pstad.init` to `/etc/init.d/pstad`
   with `scp -O`, since OpenWrt's dropbear has no `sftp-server`;
4. creates an empty `/etc/psta/allow` if none exists, and enables and restarts
   the service.

Without `pstad` beside `install.sh` it installs the packages and stops, which
prepares a device for an image build.

## Baking into an image

With the OpenWrt ImageBuilder, add the files to the `FILES=` overlay:

```
files/usr/sbin/pstad          (mode 755)
files/etc/init.d/pstad        (mode 755, a copy of pstad.init)
files/etc/psta/allow          (optional)
```

```sh
make image PROFILE=<profile> FILES=files/ \
  PACKAGES="tc-full kmod-sched-core kmod-sched-flower ip-bridge tcpdump-mini -relayd"
```

Leave out any relayd hotplug script. Enable the service with a `uci-defaults`
script or by shipping the symlink `etc/rc.d/S99pstad -> ../init.d/pstad`.
`START=99` starts it after netifd has created the backhaul station.

The companion repo `wr1800k-openwrt` does this for its `proxy` backhaul mode.

## Logging

Everything goes to syslog with tag `pstad`. Read it with `logread -e pstad`.

| Message | Meaning |
|---|---|
| `up <mac> on <port> via <iface>` | Client proxied |
| `down <mac>` | Client torn down |
| `no backhaul, not adding <mac>` | The backhaul was not associated when the client appeared |
| `<iface> did not associate in <n>s` | The station never connected; setup rolled back |
| `setup failed for <mac> on <port>` | A setup step failed; see the line before |
| `<iface> lost association` | The station stayed disconnected for `PSTA_DOWN_GRACE` |
| `<iface> has <n> supplicants` | More than one supplicant on a station; the client is rebuilt |
| `<mac> left <port>` | The client left the repeater's AP; torn down and held off |
| `<iface> dropped by the AP, client still here` | Upstream AP dropped the station; left to reconnect |
| `<iface> dropped by the AP, client gone` | Upstream AP dropped the station and the client is quiet; torn down |
| `<mac> joining <bssid> elsewhere, dropping its station` | Client heard joining the upstream BSS through another radio |
| `supplicant on <iface> did not exit in 3s` | An old supplicant would not stop; setup failed |
| `killed orphan wpa_supplicant <pid> on <iface>` | A supplicant no client owns was killed |
| `no tcpdump, clients joining the upstream BSS elsewhere go unseen` | `tcpdump` is missing |
| `<iface> forwards group frames` | That station now carries the group-frame rule |
| `backhaul now on <bssid>, dropping every station` | The backhaul's BSSID changed; every station is rebuilt |
