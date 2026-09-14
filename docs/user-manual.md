# User manual

## Commands

`pstad` takes exactly one subcommand. The init script runs the first two;
the others are for the shell.

### `pstad monitor`

The event loop. Writes the shared supplicant config (retrying every 5 s until
the backhaul is associated), then reads `bridge fdb show br br-lan` once to
pick up clients already present, and after that reads `bridge monitor fdb`
and `iw event` through a FIFO at `$RUN/fifo`. Every learned fdb entry for an
allowlisted MAC triggers a setup; an entry showing a known client on a
different port tears the old station down and rebuilds it on the new port.
Entries marked `Deleted`, `permanent` or `self` are ignored, as is a MAC on
hold-off. From `iw event`, a `del station` on a proxied client's port, or a
`disconnected (by AP)` on a proxy station, tears the client down, deletes its
fdb entry and holds the MAC off for `PSTA_HOLDOFF` seconds; a `new station`
clears the hold-off. Exits on TERM or INT after killing both children.

### `pstad sweep`

The timer loop. Every `PSTA_SWEEP` seconds it:

- compares the backhaul's current BSSID with the one the supplicant config was
  written for. If they differ, every station is torn down and the config
  rewritten, since each station is pinned to that BSSID and frequency.
- for each client, checks the station is still associated. A station reading
  "Not connected" gets a `down` marker; after `PSTA_DOWN_GRACE` seconds of
  that, the client is torn down. A station seen connected again clears the
  marker.
- reads the packet counter on the client's port-side redirect. A rising
  counter updates `seen`; a counter unchanged for `PSTA_IDLE` seconds tears the
  client down.
- kills any `wpa_supplicant` on a `psta-*` station that no client directory
  claims, logging `killed orphan wpa_supplicant <pid> on <iface>`.
- confirms the group-frame forwarder is still connected, electing another
  client's station if not.
- re-reads `bridge fdb show` once, so a client torn down and back within the
  bridge's ageing window, which raises no fdb event, is picked up again.

### `pstad teardown-all`

Removes every station, every per-client rule, the per-port EAPOL pass rule and
`clsact` qdisc on each port that had one, the backhaul's `clsact`, and the
supplicant config, and kills any `wpa_supplicant` still running on a `psta-*`
station. The init script runs this after both instances have
stopped. Safe with no clients present.

### `pstad status`

One line per client:

```
<mac> <iface> on <port>, <count> pkts, seen <date>[, forwards group frames]
```

`count` is the last value read from the redirect counter by the sweep, so it
lags by up to one sweep interval. Exactly one line carries `forwards group
frames` while any client is up.

## Environment

All are read at start; set them in the init script's instances or on the
command line for a manual run.

| Variable | Default | Meaning |
|---|---|---|
| `RUN` | `/var/run/psta` | State directory: one subdirectory per client MAC holding `iface`, `port`, `pref`, `count`, `seen` and, while a station reads not connected, `down`; plus `bssid`, `wpa.conf`, `fifo`, `lock`, `forwarder` (the MAC carrying the group-frame rule) and `holdoff/<mac>` stamps |
| `ALLOW` | `/etc/psta/allow` | Allowlist path |
| `PSTA_BRIDGE` | `br-lan` | The LAN bridge whose ports carry clients; group frames are redirected into it |
| `PSTA_IDLE` | `300` | Seconds without the redirect counter rising before a client is torn down |
| `PSTA_SWEEP` | `60` | Seconds between sweeps |
| `PSTA_ASSOC` | `20` | Seconds to wait for a new station to associate before giving up and tearing it down |
| `PSTA_DOWN_GRACE` | `120` | Seconds a station may read not connected before it is torn down |
| `PSTA_HOLDOFF` | `60` | Seconds a client torn down for leaving is ignored if re-learned from stale frames; cleared early when the AP reports it back |

## The allowlist

`/etc/psta/allow` is a plain file, one entry per line:

- a MAC address in colon form, case-insensitive, proxies that client;
- a line containing only `*` proxies every client the bridge learns.

A missing file proxies nothing. The file is read on every fdb event, so edits
take effect without a restart for new clients; an already-proxied client that
is removed from the list stays up until its idle timer fires or the service
restarts.

`*` is the setting for a deployed repeater. A MAC list is for a bench or for a
repeater that must serve only known hosts. The phy's station limit still
applies: on MT7915 the 19th client's station fails to come up and that client
is left with no path, since there is no relayd to fall back to. See
[backlog.md](backlog.md).

## install.sh

```sh
sh install.sh <repeater-host>
```

Connects as `root@<repeater-host>` over SSH and:

1. installs `tc-full kmod-sched-core kmod-sched-flower ip-bridge` if
   `tc-full` is not already installed;
2. loads `act_mirred` and `cls_flower` and confirms both are present, since the
   redirect is the whole forwarding mechanism;
3. copies `pstad` to `/usr/sbin/pstad` and `pstad.init` to
   `/etc/init.d/pstad` using `scp -O`, because OpenWrt's dropbear has no
   `sftp-server`;
4. makes both executable, creates an empty `/etc/psta/allow` if none exists,
   enables the service and restarts it.

Run from a checkout that has `pstad` beside `install.sh`. Without it the script
installs the packages and stops, which is useful for preparing a device before
building an image.

## Baking into an image

With the OpenWrt ImageBuilder, put the two files in the `FILES=` overlay and
add the package set:

```
files/usr/sbin/pstad          (mode 755)
files/etc/init.d/pstad        (mode 755, a copy of pstad.init)
files/etc/psta/allow          (optional; a lone * proxies all clients)
```

```sh
make image PROFILE=<profile> FILES=files/ \
  PACKAGES="tc-full kmod-sched-core kmod-sched-flower ip-bridge"
```

Drop `relayd` from `PACKAGES` and remove any relayd hotplug script from the
overlay. `pstad.init` has `START=99` so it starts after netifd has created the
backhaul station, and `STOP=10` so the stations are torn down early on
shutdown. Enable it with a `uci-defaults` script or by shipping the symlink
`etc/rc.d/S99pstad -> ../init.d/pstad` in the overlay.

The companion repo `wr1800k-openwrt` does this automatically for its `proxy`
backhaul mode.

## relayd

relayd and `pstad` cannot run together. relayd re-issues every host's ARP
upstream under the station's own MAC, so the upstream ends up with two paths
for a proxied host and about half its frames take the relayd path, which has
no redirect. Measured as roughly 50% packet loss with both running and 0%
with either alone. Remove relayd (package and any hotplug launcher) before
enabling `pstad`.

## Logging

Everything goes to syslog with tag `pstad`; `logread -e pstad` shows it.
Messages:

| Message | Meaning |
|---|---|
| `up <mac> on <port> via <iface>` | Client proxied |
| `down <mac>` | Client torn down |
| `no backhaul, not adding <mac>` | The backhaul was not associated when the client appeared |
| `<iface> did not associate in <n>s` | The client's station never connected; setup rolled back |
| `setup failed for <mac> on <port>` | Some step of setup failed; see the preceding line |
| `<iface> lost association` | The station read not connected for the whole grace period |
| `<mac> left <port>` | The repeater's AP reported the client gone; torn down and held off |
| `<iface> disconnected by the AP` | The upstream AP dropped the proxy station; torn down and held off |
| `<iface> forwards group frames` | That station now carries the single group-frame rule |
| `backhaul now on <bssid>, dropping every station` | The backhaul moved; all stations rebuilt against the new BSSID |
