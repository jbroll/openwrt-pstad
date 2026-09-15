# Backlog

## Capacity

The phy's managed-interface limit (19 on MT7915, one taken by the backhaul)
is not checked before setup. The 19th client's station fails at `ip link set
up`, setup rolls back, and the client stays on the bridge with no upstream
path at all, since relayd is gone. Read the limit from `iw phy` at start and
either refuse the client with a log line or keep a small relayd-like fallback
for overflow.

## Joins on other upstream channels

The monitor interface hears only the backhaul's channel. A client leaving a
repeater silently for another radio of the upstream router, a Verizon Fios
unit's 2.4 GHz or second 5 GHz radio, raises nothing, and the repeater's
station stays until hostapd's inactivity poll or `PSTA_IDLE`. Measured with a
test client moved silently to the Fios 2.4 GHz radio, that stale station cost
nothing: one ping lost at the move, none over the 5.5 minutes before it went,
and none when its teardown deauthenticated the MAC. The router keeps a
separate association per radio.

## The window with two stations

From the new station's association until the old repeater's teardown, the
router holds two associations for the client's MAC and delivers to neither.
That window is `PSTA_JOIN_DELAY` plus the wait for the old repeater's lock, and
measured about 2 s in one roam. Tearing down as soon as the new station's
4-way handshake completes, seen on the monitor as its EAPOL frames, would
shorten it, but the capture filter would then have to pass data frames on a
busy channel.

## Unattributed roam loss

Four roams between the repeaters lost 2.4 to 5.5 s of pings at 0.5 s
intervals. The slowest had about 2.5 s after the new station's reconnect that
no log line explains, and one ping lost 26 s after the roam. A captured roam
covering both repeaters and the client would attribute it.

## Roams between repeaters cost a deauthentication

When a client moves from one repeater to another, the old repeater's teardown
deauthenticates the client's MAC and the router drops the new station too. With
`PSTA_JOIN_DELAY` placing that after the new 4-way handshake, the new station
reassociates in about 0.4 s, and a test client roaming between the units lost
four pings at 0.5 s intervals in all. The old station cannot leave without
deauthenticating, since mac80211 sends one on interface removal. A way to drop
the station without transmitting would remove that second gap.

## Orphan lines after an idle teardown

A sweep that tears a client down for idling then runs `reap_orphans` at once,
before the supplicant it signalled has exited, and logs `killed orphan
wpa_supplicant` for it. `teardown-all` already waits for that; the sweep
should wait for the supplicants it signalled in the same way.

## Wired clients that unplug

No event marks a wired client leaving, so its station stays up for the idle
window. Harmless unless the same host reappears upstream within that window.
`iw event` cannot help; a link-state watch on the port would only catch the
whole port going down.
