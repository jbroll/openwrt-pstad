# Backlog

`*` in the allowlist is not yet safe on a repeater with many clients or
clients that roam between the repeater and the upstream access point. The first
three items below are what has to land before it is.

## Broadcast-forwarder election

With several proxy stations up, the access point hands its copy of every
downstream broadcast to each of them, and each station's group-frame rule
redirects it into the bridge, so one upstream broadcast arrives N times on the
LAN side. Have `pstad` designate one live station to own the downstream
group-frame rule (pref 4 on the station) and re-designate in the sweep when
that client leaves.

## Roam teardown

A client that roams from the repeater to the upstream access point directly
leaves its proxy station associated under the same MAC, fighting the client's
real association for up to the idle window (`PSTA_IDLE`, 300 s). Add a
`wpa_cli` action script that tears the station down on
`CTRL-EVENT-DISCONNECTED` and holds the MAC off for a few minutes. Needs the
`wpa-cli` package on the device.

## tc pref collision

`pref_for` derives the tc pref from the low 16 bits of the MAC (mod 65000,
plus 100), so two clients whose last two octets match land on the same pref.
On a shared port, `teardown` deletes by pref and takes the survivor's redirect
with it, and nothing self-heals. Harmless with one or two clients; at 18 the
chance of a collision is about 0.2%. Delete by filter handle, or allocate a
free pref per client instead of hashing the MAC.

## Key management

`write_conf` hardcodes `key_mgmt=SAE WPA-PSK` with `ieee80211w=1`, which is
right for a WPA2/WPA3 mixed upstream and is what an OpenWrt `sae-mixed`
station uses. It is not derived from the backhaul's own `encryption` setting,
so a `psk2`-only or SAE-only upstream needs a hand edit. Derive it from the
`wifi-iface` the backhaul is read from.
