# Backlog

## Capacity

The phy's managed-interface limit (19 on MT7915, one taken by the backhaul)
is not checked before setup. The 19th client's station fails at `ip link set
up`, setup rolls back, and the client stays on the bridge with no upstream
path at all, since relayd is gone. Read the limit from `iw phy` at start and
either refuse the client with a log line or keep a small relayd-like fallback
for overflow.

## Silent roams between repeaters

A client that roams from one repeater to another without deauthenticating
from the first leaves the first repeater's hostapd listing it, so no
`del station` arrives and its proxy station stays associated. The upstream
router then holds two associations for one MAC and delivers to neither
reliably. Measured with a test client moved from dc10 to cb26 by BSSID: cb26
built its station within 2 s, and the client answered no ping for about 90 s,
until hostapd on dc10 was told to drop it by hand. Left alone, only dc10's
`PSTA_IDLE` of 300 s or hostapd's own inactivity timer would end it. A phone
listed by both units' hostapd for 42 minutes overnight fits the same pattern.

A likely signal needs no coordination between repeaters: the router
rebroadcasts the client's group frames to every station, so the stale
repeater's backhaul drop rule for the client keeps counting while its port-side
redirect does not. A sweep, or a faster check, that sees that could tear the
station down and remove the client from its own AP with `ubus call
hostapd.<ap> del_client`.

## Roams between repeaters cost a deauthentication

When a client moves from one repeater to another, the new repeater's station
is usually up before the old one's `PSTA_LEAVE_WAIT` ends, and the old
teardown's deauthentication makes the router drop the new station too. The
supplicant recovers in about 0.35 s, but the client loses that much. The old
station cannot leave without deauthenticating, since mac80211 sends one on
interface removal. Coordinating the two repeaters, or shortening the wait with
sub-second polls, would narrow it.

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
