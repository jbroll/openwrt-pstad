# User manual

## Commands

`pstad` takes exactly one subcommand. The init script runs the first two;
the others are for the shell.

### `pstad monitor`

The event loop. Writes the shared supplicant config (retrying every 5 s until
the backhaul is associated), then reads `bridge fdb show br br-lan` once to
pick up clients already present, and after that reads `bridge monitor fdb`
and `iw event -t` through a FIFO at `$RUN/fifo`. Every learned fdb entry for an
allowlisted MAC triggers a setup; an entry showing a known client on a
different port tears the old station down and rebuilds it on the new port.
Entries marked `Deleted`, `permanent` or `self` are ignored, as is a MAC on
hold-off.

From `iw event`:

- a `del station` for a proxied client on its port is checked with
  `iw dev <port> station get <mac>` once a second for up to `PSTA_LEAVE_WAIT`
  seconds. A client back on the AP in that time has re-associated and keeps its
  station. Otherwise it is torn down, its fdb entry deleted and the MAC held off
  for `PSTA_HOLDOFF` seconds.
- a `del station` on a `psta-*` station means the upstream AP dropped it. If
  the client is on a wired port, or its AP port reports an `inactive time`
  under `PSTA_RECENT` seconds, the station is left for its supplicant to
  associate again. Otherwise the client is torn down and its fdb entry deleted,
  with no hold-off, so a client that comes back is rebuilt by its next frame.
  An event stamped no later than the second the station's setup began is
  ignored, since it belongs to the teardown of an earlier station with the same
  name.
- a `new station` clears the hold-off, and on a bridge port is handled like a
  learned fdb entry for that MAC on that port, so setup starts at association
  rather than at the client's first frame.

It also adds a monitor interface named by `PSTA_MONIF` to the backhaul phy and
reads `tcpdump` on it, filtered to authentication and association requests. A
received request to the backhaul's BSSID from a client proxied here on a
wireless port means the client is joining that BSS through another radio. The
client is torn down, its fdb entry deleted, it is removed from this repeater's
AP with `ubus call hostapd.<port> del_client`, and its MAC is held off. The
interface is recreated every 5 s while missing. Without `tcpdump` this is
skipped with a log line.

Exits on TERM or INT after killing its children and deleting the monitor
interface.

### `pstad sweep`

The timer loop. Every `PSTA_SWEEP` seconds it:

- compares the backhaul's current BSSID with the one the supplicant config was
  written for. If they differ, every station is torn down and the config
  rewritten, since each station is pinned to that BSSID and frequency.
- for each client, tears it down if more than one `wpa_supplicant` runs on its
  station, logging `<iface> has <n> supplicants`.
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
supplicant config. It then waits up to 3 s for the supplicants it signalled to
exit, and kills any `wpa_supplicant` still running on a `psta-*` station after
that, logging it as an orphan. The init script runs this after both instances have
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
| `RUN` | `/var/run/psta` | State directory: one subdirectory per client MAC holding `iface`, `port`, `pref`, `count`, `seen`, `since` (when setup began), `leaving` (a teardown for joining elsewhere is pending) and, while a station reads not connected, `down`; plus `bssid`, `wpa.conf`, `fifo`, `lock`, `forwarder` (the MAC carrying the group-frame rule) and `holdoff/<mac>` stamps |
| `ALLOW` | `/etc/psta/allow` | Allowlist path |
| `PSTA_BRIDGE` | `br-lan` | The LAN bridge whose ports carry clients; group frames are redirected into it |
| `PSTA_IDLE` | `300` | Seconds without the redirect counter rising before a client is torn down |
| `PSTA_SWEEP` | `60` | Seconds between sweeps |
| `PSTA_ASSOC` | `20` | Seconds to wait for a new station to associate before giving up and tearing it down |
| `PSTA_DOWN_GRACE` | `120` | Seconds a station may read not connected before it is torn down |
| `PSTA_HOLDOFF` | `60` | Seconds a client torn down for leaving is ignored if re-learned from stale frames; cleared early when the AP reports it back |
| `PSTA_LEAVE_WAIT` | `3` | Seconds a client the AP reported gone may take to reappear on the AP before it is torn down; covers a re-association, which deletes and re-adds the station. The monitor handles no other event meanwhile |
| `PSTA_JOIN_DELAY` | `1` | Seconds between hearing a client join the upstream BSS elsewhere and tearing its station down, so the teardown's deauthentication lands after the new association's 4-way handshake |
| `PSTA_MONIF` | `pstamon` | Name of the monitor interface added to the backhaul phy to hear clients joining the upstream BSS elsewhere |
| `PSTA_RECENT` | `10` | Seconds within which a wireless client must have been heard on its AP port for its dropped proxy station to be left to reconnect rather than torn down |

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
   `tc-full` is not already installed, and `tcpdump-mini` if no `tcpdump` is;
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
| `<mac> left <port>` | The repeater's AP reported the client gone and it did not reappear within `PSTA_LEAVE_WAIT`; torn down and held off |
| `<iface> dropped by the AP, client still here` | The upstream AP deleted the proxy station while its client is wired or recently heard; left for the supplicant to reconnect |
| `<iface> dropped by the AP, client gone` | The upstream AP deleted the proxy station and its client has gone quiet; torn down with no hold-off |
| `<mac> joining <bssid> elsewhere, dropping its station` | The client was heard associating to the backhaul's BSS through another radio; torn down, removed from this AP and held off |
| `no tcpdump, clients joining the upstream BSS elsewhere go unseen` | `tcpdump` is not installed, so the monitor interface is not used |
| `<iface> forwards group frames` | That station now carries the single group-frame rule |
| `backhaul now on <bssid>, dropping every station` | The backhaul moved; all stations rebuilt against the new BSSID |
