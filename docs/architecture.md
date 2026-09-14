# Architecture

## A station cannot bridge

An ordinary 802.11 data frame carries three addresses, and what they mean
depends on direction. A frame from a station to an access point sets To-DS and
reads {BSSID, source, destination}; the source field is the transmitter. A
frame from the access point to a station sets From-DS and reads {destination,
BSSID, source}, and the source may be any host on the wired side.

So the downstream direction can carry a foreign source address and the
upstream direction cannot. A station has no field in which to say "this frame
came from a host behind me". That asymmetry is why an access point bridges
dozens of clients faithfully while a station cannot represent even one, and it
is why 4-address WDS exists.

## What relayd does and what it loses

relayd runs two interfaces with no bridge between them, typically `br-lan`
and the station. It learns hosts on each side by watching ARP and DHCP,
installs a host route for each address, and answers ARP for that host on the
other interface. DHCP is special-cased so clients behind the repeater get
leases from the upstream router, and `-B` forwards broadcasts.

IP traffic to and from hosts behind the repeater works. What does not survive
is each host's layer-2 identity upstream: every frame leaving the station
carries the station's own address, so from the upstream segment every host
behind the repeater resolves to that one MAC.

Anything keyed on layer 2 breaks on that:

- A router that resolves a port-forward target through its own client table
  can deliver to the wrong host, since several addresses map to one MAC and the
  router picks one.
- Wake-on-LAN from upstream never reaches the host's NIC.
- PXE, which identifies the booting machine by MAC.
- IPv6 neighbour discovery, which ties an address to the link-layer address
  that answered.
- mDNS names only resolve for clients of the repeater's own access point,
  since relayd does not forward multicast across the boundary.

## What stock firmware does

Consumer repeater firmware bridges transparently. MediaTek's SDK calls the
feature "MAC Repeater"; Broadcom calls it "Proxy STA". For each downstream
client the repeater learns, it registers that client's MAC upstream as its own
station entry. The upstream access point sees ordinary stations associating
and needs no WDS, no Multi-AP, and no cooperation of any kind. The limit is a
client count in the low tens, set by the driver, not the protocol.

That feature lives in the proprietary driver. Neither `mt76`, the mainline
driver OpenWrt uses for MediaTek radios, nor `mac80211` ships anything that
presents itself as proxy STA. Mainline `mac80211` has no proxy-STA and no
proposal for one; the only "proxy" work in `cfg80211` is AP-side proxy ARP, a
different problem. `ath9k`, `ath10k` and `ath11k` offer 4-address WDS only.
No working `ebtables` or `nftables` MAC-translation scheme for a wifi station
link exists in packaged form; the one precedent is an ARP-NAT client-bridge
hack tied to the old proprietary Broadcom `wl` driver. relayd is what OpenWrt
ships because open client-side drivers cannot bridge in client mode. But the
radio and the driver hold the primitive, as measured below.

## The option space

For faithful bridging, upstream frames need somewhere to carry the real
source, and the access point must be willing to emit frames addressed to a
MAC it has never seen associate. Every mechanism satisfies both in one of a
small number of ways, and the list is closed.

Needing the access point's cooperation:

- 4-address WDS. To-DS and From-DS both set, a fourth field holding the
  original source. Most ISP routers refuse it; Verizon Fios units are one
  example that does not bridge 4-address frames.
- 802.11s mesh. Mesh frames carry up to six addresses.
- EasyMesh, Multi-AP and vendor SON. Control planes over one of the above.
  `wpa_supplicant` fails the association outright against a non-Multi-AP AP.

Needing nothing from the access point:

- Clone one MAC. The station associates as the single host behind it.
  Faithful, for exactly one host. This is what consumer "client bridge" means.
- Associate once per host. Proxy STA. The faithful multi-host answer, capped
  by the driver's concurrent-station limit. This is what `pstad` does.
- Tunnel layer 2 over the link. GRETAP, VXLAN, L2TPv3 or batman-adv over the
  station's own IP. Fully faithful including multicast, but it needs a peer on
  the wired segment to terminate the tunnel.
- Translate. relayd, or layer-2 MAC translation with a mapping table. The only
  option that scales to arbitrary hosts with no AP cooperation, no driver
  support and no tunnel peer, and unfaithful by construction.

## The driver holds 19 stations

Measured on a Fenvi WR1800K (MT7915 behind `mt7915e`, OpenWrt 24.10.0, kernel
6.6.73, mt76 dated 2025-01-14). Each phy advertises the interface combination

```
#{ IBSS } <= 1, #{ AP, mesh point } <= 16, #{ managed } <= 19,
total <= 19, #channels <= 1
```

and the managed count is real. A second station interface with a fabricated
address takes that address and associates beside the live backhaul:

```sh
iw phy phy1 interface add sta1 type managed addr 02:11:22:33:44:55
ip link set sta1 up
wpa_supplicant -B -s -i sta1 -c /tmp/wpa-sta1.conf -D nl80211
```

The supplicant config must be pinned to the backhaul's own BSSID and
frequency: `#channels <= 1` means a second station landing on another radio
of the same SSID would violate the combination. The new station then draws
its own DHCP lease, and a host on the upstream access point resolves that
lease to the fabricated MAC rather than to the repeater's station. That is the
thing relayd cannot do, done with no cooperation from the access point.

Creating interfaces is not checked against the combination; 20 were created
without error. Associating is checked. 18 test stations plus the backhaul
connected, and the next two failed at `ip link set up` with `SIOCSIFFLAGS:
Resource busy`. The limit is exactly the advertised 19, so with one slot on
the repeater's own backhaul the usable capacity is 18 proxied clients.

## How pstad works

`pstad` is the userspace that turns that primitive into a repeater. It
manages lifecycle only; the forwarding path is a fixed set of `tc` flower
rules and the kernel does the work.

### Per-client station

For each allowlisted client the bridge learns, `setup` creates a managed
interface on the backhaul phy named `psta-<last six hex digits of the MAC>`
with the client's MAC as its address, brings it up, and starts one
`wpa_supplicant -B -D nl80211` on it. Every station shares one config,
`$RUN/wpa.conf`, written once from the backhaul's `wifi-iface` in UCI (SSID,
key and encryption) and the backhaul's live `iw dev ... link` (BSSID and
frequency):

```
network={
	ssid="<ssid>"
	bssid=<backhaul bssid>
	freq_list=<backhaul freq>
	key_mgmt=SAE WPA-PSK
	ieee80211w=1
	psk="<key>"
}
```

The two auth lines follow the backhaul's `encryption`: `sae` gives
`key_mgmt=SAE` with `ieee80211w=2`, any `psk*` value gives `WPA-PSK` with
`ieee80211w=1`, and `sae-mixed` or an unset value gives `SAE WPA-PSK` with
`ieee80211w=1`.

Pinning to the BSSID and frequency is what keeps every station within the
`#channels <= 1` combination. The file is written under `umask 077` in a
subshell so the PSK is never world-readable, even briefly.

### The rule set

Two `clsact` qdiscs and six flower filters carry a client. Prefs are
evaluated in ascending order, so their numbering is the rule order. On the
client's station interface, ingress (frames arriving from the air):

| pref | match | action | why |
|---|---|---|---|
| 1 | `protocol 0x888e` (EAPOL) | pass | The 4-way handshake and rekeys must reach the supplicant, never the redirect |
| 2 | `dst_mac <client>` | mirred egress redirect to the port | Unicast for the client goes down to its bridge port |
| 3 | `src_mac <backhaul station MAC>` | drop | The AP re-broadcasts the repeater's own upstream broadcasts to every station; sent back down they read as the repeater claiming a neighbour's address. Sits before pref 4 so those copies never reach the LAN |
| 4 | `dst_mac 01:00:00:00:00:00/01:00:00:00:00:00` | mirred egress redirect to `br-lan` | Group and broadcast frames go down into the bridge, which floods them to every port. Present on one elected station only; see below |

On the backhaul station, ingress:

| pref | match | action | why |
|---|---|---|---|
| `<client pref>` | `src_mac <client>` | drop | The AP echoes the client's own frames back to the backhaul. Anything listening behind tc ingress on the backhaul (relayd's sockets, the bridge) would otherwise see the client as an upstream host |

On the client's bridge port (`lan1`, `phy0-ap0`, ...), ingress:

| pref | match | action | why |
|---|---|---|---|
| 1 | `protocol 0x888e` | pass | Shared by every client on the port. A client authenticating to the repeater's own AP must not have its EAPOL redirected |
| `<client pref>` | `src_mac <client>` | mirred egress redirect to the client's station | Everything the client sends goes up its own station and out with its own MAC |

A client's pref is the lowest integer from 100 not held by another client, read
from the `pref` files under `$RUN` at setup and stored in the client's own, so
prefs never collide with the fixed rules or with each other. Setup runs under
the daemon's lock, so two clients cannot draw the same value.

### One forwarder for group frames

The access point hands its copy of every downstream broadcast to each
associated station, so with N proxy stations an unmodified rule set would
inject each broadcast into the LAN N times. Measured on a bench with three
proxied clients: a broadcast ping from the upstream side arrived three times at
a client with a group rule on every station, and once with the rule on one.

So only one station carries pref 4, and it redirects into the bridge rather
than to its own client's port, so every port receives the frame. `elect`
picks it: the current forwarder stays while its station reads connected;
otherwise its rule is deleted, and the first client whose station is connected
takes the rule and is recorded in `$RUN/forwarder`. `elect` runs at the end of
every setup once the new station has associated, whenever the forwarder is
torn down, and at the end of every sweep. With no client up there is no
forwarder and nothing needs one.

### Clients that leave

A client that roams from the repeater to the upstream access point, or goes to
sleep, would otherwise leave its station associated under the client's MAC for
the whole idle window, against the client's real association elsewhere. The
monitor therefore also reads `iw event`, which reports every station the
repeater's own access point adds or removes:

| event | action |
|---|---|
| `<port>: del station <mac>` for a proxied client on that port | tear the client down, delete its fdb entry on that port, and hold the MAC off |
| `<station>: disconnected (by AP)` for a proxy station | the same, looked up by interface name |
| `<port>: new station <mac>` | clear any hold-off on the MAC |

The fdb deletion matters because the sweep re-reads `bridge fdb show` and
would otherwise re-proxy the client from its stale entry. The hold-off,
`PSTA_HOLDOFF` seconds (60 by default), covers frames still in flight after
the teardown. A client that comes back raises `new station` first, which clears
the hold-off before its first frame is learned, so a real return is not
delayed. On the bench a kicked client was torn down within a second of the
event, the forwarder role moved to another client in the same second, and the
client was proxied again 17 s later after it reassociated.

`iw event` writes each line as it happens even when its output is a pipe, so
the monitor reads it through the same FIFO as `bridge monitor fdb`.

Whether the upstream access point ever sends the `disconnected (by AP)` event
depends on the router. A Verizon Fios unit keeps both associations when the
same MAC associates twice and delivers to the newer one, so a client roaming
from the repeater to the router simply wins, and the repeater's own `del
station` event is what tears its station down. See
[backlog.md](backlog.md).

The `clsact` qdisc on the port and on the backhaul is added with errors
ignored, since it may already exist from an earlier client; on the client's
own station it is always fresh.

### Setup is gated on association

Order matters. The port-side redirect is the last rule installed, and only
after the station reports `Connected` in `iw dev <iface> link`, polled once a
second for up to `PSTA_ASSOC` seconds (20 by default). If the redirect went
in first, every frame the client sent would enter an unassociated interface
and vanish, the client would be dark, and the redirect counter would keep
rising, so the idle sweep would never rescue it. A station that fails to
associate is logged and torn down, and the client is left on the bridge as it
was.

The backhaul-side drop for the client's own MAC goes in after association and
before the port redirect, so the echo is hidden before the first upstream
frame is sent.

### Presence

Once redirected, the client's frames no longer enter the bridge, so the
bridge stops learning it and its fdb entry ages out with no event. The
liveness signal is therefore the port-side redirect's own packet counter, read
from `tc -s filter show` (the first `Sent ... pkt` line is the action's). The
sweep records the counter in `$RUN/<mac>/count` and the time it last rose in
`$RUN/<mac>/seen`; a counter unchanged for `PSTA_IDLE` seconds (300 by
default) tears the client down.

A station that dropped off the backhaul still attracts the client's frames
through the redirect, so the counter cannot reveal it. The sweep also checks
each station's association. A supplicant mid-reassociation reads
`Not connected` for a moment, so the first such reading only stamps
`$RUN/<mac>/down`; the client is torn down once that has persisted for
`PSTA_DOWN_GRACE` seconds (120 by default), and a station seen connected again
clears the stamp.

Every sweep ends with a pass over `bridge fdb show`, so a client that was torn
down and came straight back within the bridge's ageing window is re-proxied
even though the bridge raised no new event.

If the backhaul's BSSID has changed since the config was written, the sweep
tears down every station and rewrites the config, because each supplicant is
pinned to the old BSSID and frequency.

### Two instances under one lock

procd runs `pstad monitor` and `pstad sweep` as two instances so neither
needs job control. The monitor blocks on a FIFO fed by `bridge monitor fdb`
and `iw event`, reacting to clients arriving, moving ports or leaving; the
sweep runs every `PSTA_SWEEP` seconds (60 by default). The monitor runs each
line's handler, and the sweep each pass, through `locked`, which takes `flock`
on `$RUN/lock` on fd 9 for the duration of the call, so a setup and a teardown
for the same client never interleave.

`wpa_supplicant -B` daemonises and would inherit fd 9 and hold the lock
forever, so its command line closes the descriptor with `9>&-`. The tests
cover exactly this.

`teardown` reads each per-client file into a freshly unset variable, so a
half-written client directory from an interrupted setup never causes a
`tc filter del` against some other client's port or pref.

### Supplicants are found by command line

A `wpa_supplicant` keeps running when its interface is deleted, and takes over
a new interface created under the same name. One that a teardown failed to kill
therefore fights every later setup for that client: each new station times out
waiting for association, and the client has no upstream path until the process
is killed by hand.

A pid file cannot track them. A supplicant deletes its pid file when it exits,
so an old supplicant still shutting down while the next one for the same client
starts deletes the new one's file, and the next teardown has nothing to kill.
That was confirmed on a repeater with two supplicants given one `-P` path. So
supplicants get no pid file. `setup` and `teardown` kill every supplicant whose
command line in `/proc/<pid>/cmdline` names the station with `-i psta-xxxxxx`,
and every sweep and `teardown-all` kill any supplicant on a `psta-*` station
that no client directory claims.

`kill` only sends the signal, and a supplicant still shutting down would take
the interface `setup` creates next. So `setup` waits, checking once a second
for up to 3 s, until no supplicant names the station. If one is still there,
the setup fails and is torn down. As a backstop, a sweep that finds more than
one supplicant on a claimed station tears that client down, and the same
sweep's fdb pass rebuilds it with one. The `flock` does not cover any of this.
It serialises pstad's own actions, and these races are with processes that
have already left pstad's control.

## Why relayd cannot coexist

Measured on one host behind a repeater, three ways within the same minute:
relayd only, the wrong MAC upstream and 0% loss; relayd and proxy STA
together, about 50% loss; proxy STA only with relayd stopped, 0% loss.

relayd re-issues the host's ARP upstream under the station's own MAC, so the
upstream router learns two paths to the host, and roughly half the frames take
the relayd path, which has no redirect into the host's station. The proxy
station has to be the only path. Remove relayd, including any hotplug script
that launches it, before enabling `pstad`.

## Costs

Each proxied client takes one association slot on the backhaul phy. With the
backhaul itself in one of the 19 managed slots, 18 clients is the ceiling on
MT7915; other drivers advertise their own combination in `iw phy`.

Each client also runs its own `wpa_supplicant` process on the repeater and
does its own 4-way handshake with the upstream access point, so the access
point sees N stations from one physical device.

In return, every proxied host has its own MAC on the upstream segment:
port-forward targets resolve to the right host, Wake-on-LAN and PXE work,
IPv6 neighbour discovery works, and a host's `.local` name resolves from
anywhere on the LAN, not only from clients of the repeater's own AP.
