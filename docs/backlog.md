# Backlog

## Capacity

The phy's managed-interface limit (19 on MT7915, one taken by the backhaul)
is not checked before setup. The 19th client's station fails at `ip link set
up`, setup rolls back, and the client stays on the bridge with no upstream
path at all, since relayd is gone. Read the limit from `iw phy` at start and
either refuse the client with a log line or keep a small relayd-like fallback
for overflow.

## The kicked path on hardware

`disconnected (by AP)` on a proxy station is handled by the same code as a
client leaving, and covered by the unit tests, but has not been provoked on a
device. It needs an upstream access point that deauthenticates the old
association when the same MAC associates to another of its radios.

## Wired clients that unplug

No event marks a wired client leaving, so its station stays up for the idle
window. Harmless unless the same host reappears upstream within that window.
`iw event` cannot help; a link-state watch on the port would only catch the
whole port going down.
