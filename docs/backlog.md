# Backlog

## Capacity

The phy's managed-interface limit (19 on MT7915, one taken by the backhaul)
is not checked before setup. The 19th client's station fails at `ip link set
up`, setup rolls back, and the client stays on the bridge with no upstream
path at all, since relayd is gone. Read the limit from `iw phy` at start and
either refuse the client with a log line or keep a small relayd-like fallback
for overflow.

## The kicked path on hardware

A `del station` on a `psta-*` station tears the client down, and that event
has been seen on a device only for a local deauthentication. An upstream
deauthentication was not provoked. Two stations with one fabricated MAC, on
two repeaters, both stayed associated to a Verizon Fios router, including after
the older one sent traffic. The same router did send
`Reason: 7=CLASS3_FRAME_FROM_NONASSOC_STA` to a phone's proxy stations on both
repeaters fifteen times in one night, while hostapd on both listed the phone,
so a collision is not always silent. What sets it off is not known.

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
