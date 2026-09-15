# Architecture

## The problem

An 802.11 frame from a station to its access point has address fields for the
BSSID, the source and the destination, and the source is the station itself.
There is no field for "this frame came from a host behind me", so a repeater
whose uplink is an ordinary station cannot bridge the hosts behind it. 4-address
WDS adds that field, but most ISP routers refuse it.

`pstad` works around it. For each client behind the repeater it
creates an extra managed interface on the backhaul radio, gives it the client's
MAC, and associates it to the upstream access point. The access point sees one
ordinary station per client and needs no cooperation. `tc` rules move each
client's frames between its bridge port and its own station, so the kernel
does the forwarding and `pstad` only creates and removes stations.

The limit is the phy's interface combination. MT7915 under `mt76` advertises
`#{ managed } <= 19, #channels <= 1`. The backhaul takes one slot, leaving 18
clients, and every station must use the backhaul's channel. Other drivers
report their own limit in `iw phy`.

## Components

`pstad` is a single POSIX sh script. Its state is plain files under `$RUN`
(`/var/run/psta`), and it depends only on `iw`, `ip`, `bridge`, `tc`,
`wpa_supplicant`, `flock`, `uci`, `ubus` and optionally `tcpdump`. The tests
source it with `PSTAD_LIB=1` and replace every device command with a shell
function.

`pstad.init` has procd run two instances of the script, both respawned:

- `pstad monitor` reacts to events as they happen.
- `pstad sweep` wakes every `PSTA_SWEEP` seconds (60) to age clients out and
  repair anything the events missed.

When the service stops, `pstad teardown-all` removes every station, rule and
supplicant.

## Processes and events

```
procd
 │
 ├── pstad monitor
 │     ├── bridge monitor fdb ──┐   MACs learned on bridge ports
 │     ├── iw event -t ─────────┤   stations added or removed, on the
 │     │                        │   repeater's AP or on a proxy station
 │     ├── air watch ───────────┤   auth/assoc requests on the backhaul
 │     │   (tcpdump, pstamon)   │   channel, from a monitor interface
 │     │                        ▼
 │     │                    $RUN/fifo
 │     │                        │
 │     └── read loop ◄──────────┘   one line at a time, under the lock
 │           ├── fdb line ────────► handle        set up or move a client
 │           ├── new/del station ─► handle_event  arrive, leave, dropped by AP
 │           └── mgmt frame ──────► handle_air    client joined upstream elsewhere
 │                                    │
 │                                    └── deferred subshell: sleep, then take
 │                                        the lock and tear the client down
 │
 ├── pstad sweep
 │     └── every PSTA_SWEEP s, under the lock: idle, association and
 │         supplicant checks, forwarder election, fdb reconciliation
 │
 └── wpa_supplicant × N    one per proxy station, daemonised, found later
                           by command line

         $RUN/lock  (flock)  serialises monitor handlers, deferred
                             teardowns and sweep passes
```

The three event sources write into one FIFO, and a single loop reads it. Each
source writes whole lines smaller than `PIPE_BUF`, so lines from different
writers never interleave, and the loop needs no job control or `select`. The
air watch is a loop around `tcpdump` that recreates the monitor interface if a
wifi reload removes it. Without `tcpdump` installed the monitor logs that joins
elsewhere go unseen and runs with the other two sources.

At start the monitor waits until the backhaul is connected and the supplicant
config can be written, starts the three writers, then replays
`bridge fdb show` so clients already present are set up. Events that arrive
during the replay wait in the FIFO.

Every handler runs through `locked`, which holds `flock` on `$RUN/lock` for the
call. The monitor, the sweep and deferred teardowns therefore never act on a
client at the same time. Handlers do not lock themselves, so the tests call
them directly.

### Events and what they do

| source | event | action |
|---|---|---|
| bridge | allowlisted MAC learned on a port, not held off | set the client up, or move it if the port changed |
| AP port | `new station <mac>` | clear any hold-off, and start setup at once instead of waiting for the bridge to learn the client |
| AP port | `del station <mac>` for a proxied client | if the client is not back within `PSTA_LEAVE_WAIT` s (3), tear it down, delete its fdb entry and hold the MAC off for `PSTA_HOLDOFF` s (60) |
| proxy station | `del station <bssid>` | the upstream AP dropped the station. If the client is still here, leave the supplicant to reconnect. Otherwise tear it down, with no hold-off |
| air watch | auth or assoc request from a proxied wireless client to the backhaul's BSSID, received over the air | after `PSTA_JOIN_DELAY` s (1), tear the client down, remove it from this repeater's AP, and hold it off |

A reassociation to the same AP produces `del station` and `new station`
milliseconds apart, which is why a leave is confirmed by polling
`iw dev <port> station get` before acting.

A client is "still here" if it is on a wired port, or its AP reports an
inactive time under `PSTA_RECENT` s (10). A drop while the client is still here
is what a roam between two repeaters looks like on the new repeater: the old
repeater's teardown deauthenticates the MAC, and the router ends every
association for that MAC, including the new one.

The air watch catches a client that moves to another repeater without telling
this one's AP. Two associations for one MAC in one BSS receive nothing, so the
old station must go. Only frames with a received signal count, so this
repeater's own stations never match. Only the first `BSSID:`, `DA:` and `SA:`
in a line are read, because the SSID printed after them is chosen by the
sender. The delay lets the new station finish its 4-way handshake before this
repeater's deauthentication lands, so the router's drop costs one quick
reconnect instead of a 10 s handshake timeout. The watch hears only the
backhaul's channel.

Proxy station events are stamped with the time. Each client records in
`$RUN/<mac>/since` the second its setup began, and events no later than that
are ignored, since they may come from a teardown of the station that was just
replaced.

OpenWrt ships the tiny `iw`, which prints disconnects as `unknown event <n>`.
The `del station` for the AP's BSSID on a managed interface is the signal that
remains.

## Per-client state

Each proxied client has a directory `$RUN/<mac>/`:

| file | contents |
|---|---|
| `iface` | station name, `psta-` plus the last six hex digits of the MAC |
| `port` | the bridge port the client is on |
| `pref` | the client's `tc` filter priority |
| `count`, `seen` | last redirect packet count, and when it last rose |
| `since` | when setup began |
| `down` | when the station was first seen not connected |
| `leaving` | a join elsewhere has been heard and a teardown is pending |

Shared files are `$RUN/wpa.conf`, `$RUN/bssid`, `$RUN/forwarder`,
`$RUN/holdoff/<mac>` and `$RUN/lock`. `teardown` reads each file into a freshly
unset variable, so a half-written directory can never direct a `tc filter del`
at another client's port or pref.

## Setup

Every station shares one supplicant config, written from the backhaul's UCI
section (SSID, key, encryption) and its live link (BSSID, frequency):

```
network={
	ssid="<ssid>"
	bssid=<backhaul bssid>
	freq_list=<backhaul freq>
	scan_freq=<backhaul freq>
	key_mgmt=SAE WPA-PSK
	ieee80211w=1
	psk="<key>"
}
```

Pinning the BSSID and frequency keeps every station on the one allowed channel.
`scan_freq` limits the first scan to that channel. Without it, a station scans
the whole band, and on a DFS channel that scan times out after 10 s. The auth
lines follow `encryption`: `sae` gives `SAE` with `ieee80211w=2`, `psk*` gives
`WPA-PSK`, anything else gives both. The file is written under `umask 077`.

`setup` then:

1. Stops any supplicant still running for the station name.
2. Adds the managed interface with the client's MAC, brings it up, and starts
   `wpa_supplicant` on it.
3. Installs the station-side rules.
4. Waits up to `PSTA_ASSOC` s (20) for the station to report `Connected`.
5. Runs the forwarder election.
6. Installs the backhaul-side drop, then the port-side redirect last.

The port redirect waits for association because a client redirected into an
unassociated station goes dark, while the rising redirect counter hides it from
the idle check. If any step fails, the client is torn down and stays on the
bridge as it was.

## The rule set

Each interface involved gets a `clsact` qdisc and flower filters on ingress.
Lower prefs match first.

On the client's station (frames from the air):

| pref | match | action | why |
|---|---|---|---|
| 1 | EAPOL (`0x888e`) | pass | the handshake must reach the supplicant |
| 2 | `dst_mac <client>` | redirect to the client's port | unicast for the client |
| 3 | `src_mac <backhaul MAC>` | drop | the AP repeats the repeater's own broadcasts to every station, and sent down they look like the repeater claiming a neighbour's address |
| 4 | group bit set in `dst_mac` | redirect to `br-lan` | broadcast and multicast, flooded to every port. On the forwarder only |

On the backhaul station:

| pref | match | action | why |
|---|---|---|---|
| client's | `src_mac <client>` | drop | the AP echoes the client's own frames back, and the repeater would learn the client as an upstream host |

On the client's bridge port:

| pref | match | action | why |
|---|---|---|---|
| 1 | EAPOL | pass | clients authenticating to the repeater's own AP |
| client's | `src_mac <client>` | redirect to the client's station | everything the client sends leaves under its own MAC |

A client's pref is the lowest integer from 100 not held by another client.
Setup runs under the lock, so two clients never draw the same value.

### One forwarder for group frames

The AP gives every associated station its own copy of each broadcast, so a
group rule on every station would put N copies into the LAN. Only one station,
the forwarder named in `$RUN/forwarder`, carries pref 4. The election keeps the
current forwarder while its station is connected, and otherwise moves the rule
to the first connected station. It runs after each setup, when the forwarder is
torn down, and at the end of each sweep.

## The sweep

A redirected client's frames bypass the bridge, so its fdb entry ages out
without an event. Each sweep:

1. Compares the backhaul's BSSID with `$RUN/bssid`. If it changed, tears
   everything down and rewrites the config, since every supplicant is pinned
   to the old one.
2. Tears down a client whose station has more than one supplicant.
3. Tears down a client whose station has read not connected for
   `PSTA_DOWN_GRACE` s (120). A supplicant reassociating reads not connected
   briefly, hence the grace period.
4. Reads the port redirect's packet counter from `tc -s filter show` and tears
   down a client whose counter has not risen for `PSTA_IDLE` s (300).
5. Kills supplicants on `psta-*` stations no client directory claims.
6. Runs the forwarder election.
7. Replays `bridge fdb show`, so a client torn down and back within the
   bridge's ageing window is set up again.

## Supplicants are found by command line

A `wpa_supplicant` survives the deletion of its interface and takes over a new
interface created under the same name, where it fights the new supplicant and
blocks association. Pid files cannot track them, because an exiting supplicant
deletes its pid file even when a newer one has rewritten it. So supplicants get
no pid file. `pstad` finds them by scanning `/proc/*/cmdline` for
`wpa_supplicant ... -i psta-xxxxxx`, kills the ones for a station, and waits up
to 3 s for them to exit before creating the interface again.

`wpa_supplicant -B` would inherit the lock descriptor and hold the lock
forever, so it is started with fd 9 closed.

## Costs

Each client uses one of the phy's managed slots, one `wpa_supplicant` process,
and its own association and 4-way handshake with the upstream access point. In
return each host has its own MAC upstream: port forwards reach the right host,
Wake-on-LAN and PXE work, IPv6 neighbour discovery works, and `.local` names
resolve from anywhere on the LAN. The README explains why relayd cannot do
this and cannot run alongside `pstad`.
