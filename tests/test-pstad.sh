#!/bin/sh
# Run from anywhere: sh tests/test-pstad.sh
cd "$(dirname "$0")/.." || exit 1
PSTAD_LIB=1 . ./pstad
PROC=$(mktemp -d)
fail=0
check() {  # name expected actual
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi
}

mac=02:00:00:00:be:ef
mac2=02:00:00:00:ca:fe
check "fdb wired"          "$mac lan1"     "$(fdb_learned "$mac dev lan1 master br-lan")"
check "fdb wireless vlan"  "$mac phy0-ap0" "$(fdb_learned "$mac dev phy0-ap0 vlan 1 master br-lan")"
check "fdb deleted"        ""              "$(fdb_learned "Deleted $mac dev lan1 master br-lan")"
check "fdb permanent"      ""              "$(fdb_learned "02:00:00:00:00:11 dev lan1 master br-lan permanent")"
check "fdb self"           ""              "$(fdb_learned "$mac dev lan1 self")"
fdb_learned "Deleted $mac dev lan1 master br-lan"; check "fdb deleted status" 1 $?

check "iw new station"  "arrive phy0-ap0 $mac" "$(iw_event "phy0-ap0 (phy #0): new station $mac")"
check "iw del station"  "leave phy0-ap0 $mac"  "$(iw_event "phy0-ap0 (phy #0): del station $mac")"
check "iw no phy tag"   "leave phy0-ap0 $mac"  "$(iw_event "phy0-ap0: del station $mac")"
check "iw kicked"       "kicked psta-00beef"   "$(iw_event "psta-00beef (phy #1): disconnected (by AP) reason: 2: Previous authentication no longer valid")"
check "iw local disc"   ""                     "$(iw_event "psta-00beef (phy #1): disconnected (local request)")"
check "iw other event"  ""                     "$(iw_event "phy1-sta0 (phy #1): scan finished: 5180 5200")"
iw_event "phy1-sta0 (phy #1): connected to 02:00:00:00:00:20"; check "iw other status" 1 $?

link='Connected to 02:00:00:00:00:20 (on phy1-sta0)
	SSID: example-ssid
	freq: 5660.0
	RX: 1 bytes (1 packets)'
check "link params"   "02:00:00:00:00:20 5660" "$(printf '%s\n' "$link" | link_params)"
check "link down"     ""                       "$(echo 'Not connected.' | link_params)"

check "sent pkts"  32            "$(sent_pkts < tests/tc-stats.txt)"
check "iface"      psta-00beef   "$(iface_for $mac)"

check "key mgmt sae"      "key_mgmt=SAE
ieee80211w=2"      "$(key_mgmt sae)"
check "key mgmt psk2"     "key_mgmt=WPA-PSK
ieee80211w=1"      "$(key_mgmt psk2)"
check "key mgmt psk-mixed" "key_mgmt=WPA-PSK
ieee80211w=1"      "$(key_mgmt psk-mixed)"
check "key mgmt sae-mixed" "key_mgmt=SAE WPA-PSK
ieee80211w=1"      "$(key_mgmt sae-mixed)"
check "key mgmt unset"     "key_mgmt=SAE WPA-PSK
ieee80211w=1"      "$(key_mgmt '')"

# alloc_pref: lowest free from 100, skipping every pref in use
RUN=$(mktemp -d)
check "pref first"  100 "$(alloc_pref)"
mkdir -p "$RUN/a" "$RUN/b" "$RUN/c"; echo 100 > "$RUN/a/pref"; echo 101 > "$RUN/b/pref"; echo 103 > "$RUN/c/pref"
check "pref gap"    102 "$(alloc_pref)"
echo 102 > "$RUN/c/pref"
check "pref next"   103 "$(alloc_pref)"
rm -rf "$RUN"

ALLOW=$(mktemp); printf '%s\n' "$mac" > "$ALLOW"
allowed "$mac";               check "allowed"     0 $?
allowed 00:11:22:33:44:55;    check "not allowed" 1 $?
ALLOW=/nonexistent; allowed "$mac"; check "no allowlist" 1 $?
ALLOW=$(mktemp); printf '*\n' > "$ALLOW"
allowed 00:11:22:33:44:55; check "wildcard proxies any" 0 $?

# holdoff: held for HOLDOFF seconds, then the marker clears itself
RUN=$(mktemp -d); HOLDOFF=60
holdoff "$mac"; held "$mac"; check "held after holdoff" 0 $?
echo $(( $(date +%s) - 100 )) > "$RUN/holdoff/$mac"
held "$mac"; check "held expires" 1 $?
[ -f "$RUN/holdoff/$mac" ]; check "held removes expired marker" 1 $?
held "$mac2"; check "held unknown mac" 1 $?
rm -rf "$RUN"

# psta_supplicants: only wpa_supplicant processes on a psta-* station
mkdir -p "$PROC/123" "$PROC/124" "$PROC/125" "$PROC/126" "$PROC/127"
printf 'wpa_supplicant\0-B\0-D\0nl80211\0-i\0psta-00beef\0-c\0/var/run/psta/wpa.conf\0' > "$PROC/123/cmdline"
printf '/usr/sbin/wpa_supplicant\0-n\0-s\0-g\0/var/run/wpa_supplicant/global\0' > "$PROC/124/cmdline"
printf 'ash\0-c\0ps w | grep wpa_supplicant -i psta-00beef\0' > "$PROC/125/cmdline"
: > "$PROC/126/cmdline"
printf 'wpa_supplicant\0-i\0phy1-sta0\0' > "$PROC/127/cmdline"
check "psta supplicants" "123 psta-00beef" "$(psta_supplicants)"
rm -rf "${PROC:?}"/*

# Lifecycle logic with the device-touching functions replaced.
RUN=$(mktemp -d); ALLOW=$RUN/allow; CONF=$RUN/wpa.conf; printf '%s\n' "$mac" > "$ALLOW"
setup()    { echo "setup $*"; }
teardown() { echo "teardown $1"; rm -rf "$RUN/$1"; }
bridge()   { :; }

check "handle not allowed"  ""                 "$(handle "00:11:22:33:44:55 dev lan1 master br-lan")"
check "handle new client"   "setup $mac lan1"  "$(handle "$mac dev lan1 master br-lan")"
mkdir -p "$RUN/$mac"; echo lan1 > "$RUN/$mac/port"
check "handle same port"    ""                 "$(handle "$mac dev lan1 master br-lan")"
check "handle moved port"   "teardown $mac
setup $mac phy0-ap0"                           "$(handle "$mac dev phy0-ap0 master br-lan")"
holdoff "$mac"
check "handle held client"  ""                 "$(handle "$mac dev lan1 master br-lan")"
rm -rf "$RUN/holdoff"

# handle_event: leave tears down, deletes the fdb entry and holds the MAC off
mkdir -p "$RUN/$mac"; echo phy0-ap0 > "$RUN/$mac/port"; echo psta-00beef > "$RUN/$mac/iface"
bridge() { echo "bridge $*"; }
check "event leave"  "teardown $mac
bridge fdb del $mac dev phy0-ap0 master" "$(handle_event "phy0-ap0 (phy #0): del station $mac")"
held "$mac"; check "event leave holds off" 0 $?
mkdir -p "$RUN/$mac"; echo lan1 > "$RUN/$mac/port"
check "event leave other port" "" "$(handle_event "phy0-ap0 (phy #0): del station $mac")"
check "event leave unknown"    "" "$(handle_event "phy0-ap0 (phy #0): del station $mac2")"
check "event arrive clears"    "" "$(handle_event "phy0-ap0 (phy #0): new station $mac")"
held "$mac"; check "event arrive cleared holdoff" 1 $?
rm -rf "$RUN/$mac"

# handle_event: a station the AP disconnected is torn down by its iface name
mkdir -p "$RUN/$mac"; echo phy0-ap0 > "$RUN/$mac/port"; echo psta-00beef > "$RUN/$mac/iface"
check "event kicked" "teardown $mac
bridge fdb del $mac dev phy0-ap0 master" "$(handle_event "psta-00beef (phy #1): disconnected (by AP) reason: 2")"
held "$mac"; check "event kicked holds off" 0 $?
check "event kicked unknown iface" "" "$(handle_event "psta-00cafe (phy #1): disconnected (by AP) reason: 2")"
rm -rf "$RUN/$mac" "$RUN/holdoff"

# dispatch routes iw lines to handle_event and fdb lines to handle
handle()       { echo "handle $1"; }
handle_event() { echo "event $1"; }
check "dispatch fdb"  "handle $mac dev lan1 master br-lan" "$(dispatch "$mac dev lan1 master br-lan")"
check "dispatch iw"   "event phy0-ap0 (phy #0): del station $mac" "$(dispatch "phy0-ap0 (phy #0): del station $mac")"
check "dispatch disc" "event psta-00beef (phy #1): disconnected (by AP)" "$(dispatch "psta-00beef (phy #1): disconnected (by AP)")"
PSTAD_LIB=1 . ./pstad
setup()    { echo "setup $*"; }
teardown() { echo "teardown $1"; rm -rf "$RUN/$1"; }
bridge()   { :; }

# sweep: counter moved -> stays; counter still for IDLE -> torn down
mkdir -p "$RUN/$mac"
echo lan1 > "$RUN/$mac/port"; echo 100 > "$RUN/$mac/pref"
echo 02:00:00:00:00:20 > "$RUN/bssid"
backhaul() { echo phy1-sta0; }
iw() { printf 'Connected to 02:00:00:00:00:20 (on phy1-sta0)\n\tfreq: 5660.0\n'; }
tc() { case "$1" in -s) cat tests/tc-stats.txt;; esac; }
elect() { :; }
echo 10 > "$RUN/$mac/count"; echo $(( $(date +%s) - 400 )) > "$RUN/$mac/seen"
check "sweep counter moved" ""              "$(sweep)"
check "sweep count updated" 32              "$(cat "$RUN/$mac/count")"
echo $(( $(date +%s) - 400 )) > "$RUN/$mac/seen"
check "sweep idle"          "teardown $mac" "$(sweep)"
mkdir -p "$RUN/$mac"; echo lan1 > "$RUN/$mac/port"; echo 100 > "$RUN/$mac/pref"
echo 32 > "$RUN/$mac/count"; date +%s > "$RUN/$mac/seen"
iw() { printf 'Connected to 02:00:00:00:00:21 (on phy1-sta0)\n\tfreq: 5220.0\n'; }
write_conf() { echo "write_conf"; }
check "sweep backhaul moved" "teardown $mac
write_conf"                                "$(sweep)"
rm -rf "$RUN"

# Reset to the real setup/teardown/teardown_all/write_conf/elect, undoing the
# lifecycle-test stubs above.
PSTAD_LIB=1 . ./pstad

# teardown on a half-written (empty) client dir must not touch any device
RUN=$(mktemp -d)
mkdir -p "$RUN/$mac"
iw() { echo "iw $*"; }
tc() { echo "tc $*"; }
kill() { echo "kill $*"; }
check "teardown empty dir touches no device" "" "$(teardown "$mac")"
[ -d "$RUN/$mac" ]; check "teardown empty dir removes it" 1 $?
rm -rf "$RUN"

# teardown kills every supplicant on the client's station before deleting it,
# including one its pid file does not name
RUN=$(mktemp -d)
mkdir -p "$RUN/$mac"; echo psta-00beef > "$RUN/$mac/iface"; echo 111 > "$RUN/$mac/pid"
backhaul() { echo phy1-sta0; }
log() { :; }
psta_supplicants() { printf '111 psta-00beef\n555 psta-00beef\n777 psta-00cafe\n'; }
out=$(teardown "$mac")
check "teardown kills an untracked supplicant" 1 "$(echo "$out" | grep -cx "kill 555")"
check "teardown spares other stations' supplicants" 0 "$(echo "$out" | grep -cx "kill 777")"
kill_line=$(echo "$out" | grep -nx "kill 555" | cut -d: -f1)
del_line=$(echo "$out" | grep -nx "iw dev psta-00beef del" | cut -d: -f1)
[ -n "$kill_line" ] && [ -n "$del_line" ] && [ "$kill_line" -lt "$del_line" ]
check "teardown kills before deleting the interface" 0 $?
rm -rf "$RUN"
unset -f backhaul log
psta_supplicants() { :; }

# teardown_all: one tc qdisc del per port that appeared, wpa.conf gone, returns 0
RUN=$(mktemp -d); CONF=$RUN/wpa.conf
mkdir -p "$RUN/mac1" "$RUN/mac2"
printf 'ifaceA\n' > "$RUN/mac1/iface"; printf 'lan1\n' > "$RUN/mac1/port"; printf '101\n' > "$RUN/mac1/pref"
printf 'ifaceB\n' > "$RUN/mac2/iface"; printf 'phy0-ap0\n' > "$RUN/mac2/port"; printf '102\n' > "$RUN/mac2/pref"
echo mac1 > "$RUN/forwarder"
holdoff "$mac"
: > "$CONF"
iw() { :; }
tc() { echo "tc $*"; }
backhaul() { echo phy1-sta0; }
log() { echo "log $*"; }
out=$(teardown_all)
echo "$out" | grep -q "down holdoff"
check "teardown_all skips the holdoff dir" 1 $?
[ -d "$RUN/holdoff" ]; check "teardown_all clears holdoffs" 1 $?
unset -f log
echo "$out" | grep -qxF 'tc qdisc del dev lan1 clsact'
check "teardown_all clears lan1 clsact" 0 $?
echo "$out" | grep -qxF 'tc qdisc del dev phy0-ap0 clsact'
check "teardown_all clears phy0-ap0 clsact" 0 $?
echo "$out" | grep -qxF 'tc filter del dev phy1-sta0 ingress pref 101'
check "teardown removes the backhaul drop" 0 $?
echo "$out" | grep -qxF 'tc qdisc del dev phy1-sta0 clsact'
check "teardown_all clears backhaul clsact" 0 $?
echo "$out" | grep -q 'pref 4'
check "teardown_all never re-elects" 1 $?
unset -f backhaul
[ -f "$CONF" ]; check "teardown_all removes wpa.conf" 1 $?
[ -f "$RUN/forwarder" ]; check "teardown_all clears forwarder" 1 $?
teardown_all; check "teardown_all returns 0 with no clients" 0 $?
rm -rf "$RUN"

# teardown_all also kills supplicants no client dir accounts for
RUN=$(mktemp -d); CONF=$RUN/wpa.conf
iw() { :; }
tc() { :; }
log() { :; }
kill() { echo "kill $*"; }
psta_supplicants() { echo '777 psta-00dead'; }
check "teardown_all kills unclaimed supplicants" "kill 777" "$(teardown_all)"
rm -rf "$RUN"
unset -f iw tc log
psta_supplicants() { :; }

# elect: keeps a connected forwarder, moves the rule off a disconnected one,
# skips disconnected candidates, and does nothing with no candidates
RUN=$(mktemp -d); BRIDGE=br-lan
tc() { echo "tc $*"; }
log() { :; }
connected=""
iw() { case "$*" in *"dev $connected link"*) echo 'Connected to 02:00:00:00:00:20';; *) echo 'Not connected.';; esac; }
elect; check "elect nothing to elect" 1 $?
mkdir -p "$RUN/$mac" "$RUN/$mac2"
echo psta-00beef > "$RUN/$mac/iface"; echo 100 > "$RUN/$mac/pref"
echo psta-00cafe > "$RUN/$mac2/iface"; echo 101 > "$RUN/$mac2/pref"
connected=psta-00cafe
check "elect picks the connected station" \
	"tc filter add dev psta-00cafe ingress pref 4 protocol all flower dst_mac 01:00:00:00:00:00/01:00:00:00:00:00 action mirred egress redirect dev br-lan" \
	"$(elect)"
elect >/dev/null; check "elect forwarder recorded" "$mac2" "$(forwarder)"
check "elect keeps a connected forwarder" "" "$(elect)"
connected=psta-00beef
check "elect moves the rule off a disconnected forwarder" \
	"tc filter del dev psta-00cafe ingress pref 4
tc filter add dev psta-00beef ingress pref 4 protocol all flower dst_mac 01:00:00:00:00:00/01:00:00:00:00:00 action mirred egress redirect dev br-lan" \
	"$(elect)"
elect >/dev/null; check "elect new forwarder recorded" "$mac" "$(forwarder)"
connected=""
elect >/dev/null; check "elect with nothing connected fails" 1 $?
[ -f "$RUN/forwarder" ]; check "elect with nothing connected clears forwarder" 1 $?
rm -rf "$RUN"
unset -f tc log iw

# teardown of the forwarder re-elects; teardown of another client does not
RUN=$(mktemp -d)
mkdir -p "$RUN/$mac" "$RUN/$mac2"
echo psta-00beef > "$RUN/$mac/iface"; echo lan1 > "$RUN/$mac/port"; echo 100 > "$RUN/$mac/pref"
echo psta-00cafe > "$RUN/$mac2/iface"; echo lan1 > "$RUN/$mac2/port"; echo 101 > "$RUN/$mac2/pref"
echo "$mac" > "$RUN/forwarder"
tc() { echo "tc $*"; }
iw() { case "$*" in *link*) echo 'Connected to 02:00:00:00:00:20';; esac; }
backhaul() { echo phy1-sta0; }
log() { :; }
out=$(teardown "$mac")
echo "$out" | grep -q "tc filter add dev psta-00cafe ingress pref 4"
check "teardown forwarder re-elects" 0 $?
check "teardown forwarder recorded" "$mac2" "$(forwarder)"
mkdir -p "$RUN/$mac"; echo psta-00beef > "$RUN/$mac/iface"; echo lan1 > "$RUN/$mac/port"; echo 100 > "$RUN/$mac/pref"
out=$(teardown "$mac")
echo "$out" | grep -q "pref 4"
check "teardown non-forwarder leaves the rule" 1 $?
rm -rf "$RUN"
unset -f tc iw backhaul log

# wait_assoc: returns once the station reports Connected, fails after ASSOC
ASSOC=2
iw() { printf 'Connected to 02:00:00:00:00:20 (on %s)\n' "$3"; }
wait_assoc psta-00beef; check "wait_assoc connected" 0 $?
iw() { echo 'Not connected.'; }
log() { echo "log $*"; }
sleep() { :; }
check "wait_assoc timeout logs" "log psta-00beef did not associate in 2s" "$(wait_assoc psta-00beef)"
wait_assoc psta-00beef >/dev/null; check "wait_assoc timeout status" 1 $?
unset -f log sleep

# setup: a station that never associates must not reach the port-side redirect
# or the group rule
RUN=$(mktemp -d); CONF=$RUN/wpa.conf
echo 02:00:00:00:00:20 > "$RUN/bssid"
backhaul() { echo phy1-sta0; }
backhaul_mac() { echo 02:00:00:00:00:10; }
phy_of() { echo phy1; }
ip() { :; }
wpa_supplicant() { :; }
iw() { case "$*" in *link*) echo 'Not connected.';; esac; }
sleep() { :; }
tc() { echo "tc $*"; }
log() { :; }
teardown() { echo "teardown $1"; rm -rf "$RUN/$1"; }
out=$(PSTA_ASSOC=1 ASSOC=1 setup "$mac" lan1)
teardown_seen=$(echo "$out" | grep -c "^teardown $mac$")
src_mac_seen=$(echo "$out" | grep -c "dev lan1 ingress .* src_mac")
check "setup never installs port redirect without assoc" "1 0" "$teardown_seen $src_mac_seen"
group_seen=$(echo "$out" | grep -c "pref 4")
check "setup adds no group rule without assoc" 0 "$group_seen"
drop_seen=$(echo "$out" | grep -c "dev phy1-sta0 ingress .* action drop")
check "setup adds no backhaul drop without assoc" 0 "$drop_seen"

# setup with an associating station: pref 3 drop, then the elected group rule
# into the bridge, then the backhaul drop, then the port redirect
mkdir -p "$RUN"; echo 02:00:00:00:00:20 > "$RUN/bssid"
iw() { case "$*" in *link*) echo 'Connected to 02:00:00:00:00:20';; esac; }
out=$(setup "$mac" lan1)
line() { echo "$out" | grep -n "$1" | cut -d: -f1; }
relayd_drop=$(line "dev psta-00beef ingress pref 3 protocol all flower src_mac 02:00:00:00:00:10 action drop")
group_line=$(line "dev psta-00beef ingress pref 4 protocol all flower dst_mac 01:00:00:00:00:00/01:00:00:00:00:00 action mirred egress redirect dev br-lan")
drop_line=$(line "dev phy1-sta0 ingress pref 100 protocol all flower src_mac $mac action drop")
redirect_line=$(line "dev lan1 ingress pref 100 protocol all flower src_mac $mac action mirred")
[ -n "$relayd_drop" ] && [ -n "$group_line" ] && [ "$relayd_drop" -lt "$group_line" ]
check "setup drops the backhaul's own copies before the group rule" 0 $?
[ -n "$group_line" ] && [ -n "$drop_line" ] && [ "$group_line" -lt "$drop_line" ]
check "setup elects the group rule into the bridge before the backhaul drop" 0 $?
[ -n "$drop_line" ] && [ -n "$redirect_line" ] && [ "$drop_line" -lt "$redirect_line" ]
check "setup drops the client's backhaul echo before redirecting" 0 $?
check "setup records the forwarder" "$mac" "$(forwarder)"
check "setup allocated pref" 100 "$(cat "$RUN/$mac/pref")"
# a second client joins: gets the next pref and no group rule of its own
out=$(setup "$mac2" lan1)
check "setup second pref" 101 "$(cat "$RUN/$mac2/pref")"
echo "$out" | grep -q "pref 4"
check "setup second client adds no group rule" 1 $?
rm -rf "$RUN"
unset -f backhaul backhaul_mac phy_of ip wpa_supplicant iw sleep log teardown

# setup: shared stubs for the next two blocks
backhaul() { echo phy1-sta0; }
backhaul_mac() { echo 02:00:00:00:00:10; }
phy_of() { echo phy1; }
ip() { :; }
wpa_supplicant() { :; }
iw() { case "$*" in *link*) echo 'Connected to 02:00:00:00:00:20';; *) echo "iw $*";; esac; }
sleep() { :; }
tc() { echo "tc $*"; }
log() { :; }
kill() { echo "kill $*"; }

# setup kills a supplicant already on its station name before creating the interface
RUN=$(mktemp -d); CONF=$RUN/wpa.conf
echo 02:00:00:00:00:20 > "$RUN/bssid"
psta_supplicants() { printf '555 psta-00beef\n777 psta-00cafe\n'; }
out=$(setup "$mac" lan1)
kill_line=$(echo "$out" | grep -nx "kill 555" | cut -d: -f1)
add_line=$(echo "$out" | grep -n "interface add psta-00beef" | cut -d: -f1)
[ -n "$kill_line" ] && [ -n "$add_line" ] && [ "$kill_line" -lt "$add_line" ]
check "setup kills a leftover supplicant before adding the interface" 0 $?
check "setup spares other stations' supplicants" 0 "$(echo "$out" | grep -cx "kill 777")"
rm -rf "$RUN"

# setup gives the supplicant no pid file: an exiting supplicant deletes its pid
# file, which is the new one's when both were given the same path
RUN=$(mktemp -d); CONF=$RUN/wpa.conf
echo 02:00:00:00:00:20 > "$RUN/bssid"
wpa_supplicant() { echo "wpa_supplicant $*"; }
out=$(setup "$mac" lan1)
check "setup starts the supplicant without a pid file" 0 "$(echo "$out" | grep '^wpa_supplicant ' | grep -c -- ' -P ')"
rm -rf "$RUN"
wpa_supplicant() { :; }
psta_supplicants() { :; }

# setup redirects the port into its own station even when it elects another
# client's station as forwarder
RUN=$(mktemp -d); CONF=$RUN/wpa.conf
echo 02:00:00:00:00:20 > "$RUN/bssid"
mkdir -p "$RUN/$mac"; echo psta-00beef > "$RUN/$mac/iface"; echo 100 > "$RUN/$mac/pref"
out=$(setup "$mac2" lan1)
check "setup elected $mac" "$mac" "$(forwarder)"
echo "$out" | grep -qxF "tc filter add dev lan1 ingress pref 101 protocol all flower src_mac $mac2 action mirred egress redirect dev psta-00cafe"
check "setup redirect survives an election" 0 $?
rm -rf "$RUN"
unset -f backhaul backhaul_mac phy_of ip wpa_supplicant iw sleep log

# sweep: a station read Not connected once gets a grace period, not an immediate teardown
RUN=$(mktemp -d); d=$RUN/$mac
mkdir -p "$d"
echo lan1 > "$d/port"; echo 100 > "$d/pref"
echo 0 > "$d/count"; date +%s > "$d/seen"
echo psta-00beef > "$d/iface"
echo 02:00:00:00:00:20 > "$RUN/bssid"
backhaul() { echo phy1-sta0; }
bridge() { :; }
teardown() { echo "teardown $1"; rm -rf "$RUN/$1"; }
log() { :; }
elect() { :; }
iw() { case "$2" in phy1-sta0) printf 'Connected to 02:00:00:00:00:20 (on phy1-sta0)\n\tfreq: 5660.0\n';; *) echo 'Not connected.';; esac; }
check "sweep grace period no immediate teardown" "" "$(sweep)"
[ -f "$d/down" ]; check "sweep grace period creates down marker" 0 $?

echo $(( $(date +%s) - 200 )) > "$d/down"
check "sweep grace period expired tears down" "teardown $mac" "$(sweep)"
rm -rf "$RUN"

# sweep: a station seen connected again clears the down marker without tearing down
RUN=$(mktemp -d); d=$RUN/$mac
mkdir -p "$d"
echo lan1 > "$d/port"; echo 100 > "$d/pref"
echo 0 > "$d/count"; date +%s > "$d/seen"
echo psta-00beef > "$d/iface"
echo $(( $(date +%s) - 200 )) > "$d/down"
echo 02:00:00:00:00:20 > "$RUN/bssid"
iw() { printf 'Connected to 02:00:00:00:00:20 (on phy1-sta0)\n\tfreq: 5660.0\n'; }
check "sweep reconnect clears down marker" "" "$(sweep)"
[ -f "$d/down" ]; check "sweep reconnect removes down marker" 1 $?
rm -rf "$RUN"
unset -f log teardown backhaul bridge iw elect

# sweep tears down a client whose station has dropped off the backhaul
RUN=$(mktemp -d)
mkdir -p "$RUN/$mac"
echo lan1 > "$RUN/$mac/port"; echo 100 > "$RUN/$mac/pref"
echo 0 > "$RUN/$mac/count"; date +%s > "$RUN/$mac/seen"
echo psta-00beef > "$RUN/$mac/iface"
echo 02:00:00:00:00:20 > "$RUN/bssid"
backhaul() { echo phy1-sta0; }
bridge() { :; }
teardown() { echo "teardown $1"; rm -rf "$RUN/$1"; }
log() { :; }
elect() { :; }
# The backhaul is up; only the client's own station is down, and its grace
# period has already elapsed.
echo $(( $(date +%s) - 200 )) > "$RUN/$mac/down"
iw() { case "$2" in phy1-sta0) printf 'Connected to 02:00:00:00:00:20 (on phy1-sta0)\n\tfreq: 5660.0\n';; *) echo 'Not connected.';; esac; }
check "sweep drops unassociated station" "teardown $mac" "$(sweep)"
rm -rf "$RUN"
unset -f log teardown elect

# sweep skips a directory missing seen, without touching anything
RUN=$(mktemp -d)
mkdir -p "$RUN/$mac"
echo lan1 > "$RUN/$mac/port"; echo 100 > "$RUN/$mac/pref"; echo 0 > "$RUN/$mac/count"
echo 02:00:00:00:00:20 > "$RUN/bssid"
backhaul() { echo phy1-sta0; }
iw() { printf 'Connected to 02:00:00:00:00:20 (on phy1-sta0)\n\tfreq: 5660.0\n'; }
bridge() { :; }
elect() { :; }
check "sweep skips dir missing seen" "" "$(sweep)"
rm -rf "$RUN"

# sweep re-elects when the forwarder is gone
RUN=$(mktemp -d)
mkdir -p "$RUN/$mac"
echo lan1 > "$RUN/$mac/port"; echo 100 > "$RUN/$mac/pref"; echo 0 > "$RUN/$mac/count"; date +%s > "$RUN/$mac/seen"
echo psta-00beef > "$RUN/$mac/iface"
echo 02:00:00:00:00:20 > "$RUN/bssid"
unset -f elect
PSTAD_LIB=1 . ./pstad
backhaul() { echo phy1-sta0; }
iw() { printf 'Connected to 02:00:00:00:00:20 (on phy1-sta0)\n\tfreq: 5660.0\n'; }
bridge() { :; }
tc() { case "$1" in -s) cat tests/tc-stats.txt;; *) echo "tc $*";; esac; }
log() { :; }
out=$(sweep)
echo "$out" | grep -q "tc filter add dev psta-00beef ingress pref 4"
check "sweep elects a forwarder" 0 $?
check "sweep forwarder recorded" "$mac" "$(forwarder)"
rm -rf "$RUN"
unset -f backhaul iw bridge tc log

# sweep kills a psta supplicant no client dir claims, and leaves claimed ones
RUN=$(mktemp -d)
mkdir -p "$RUN/$mac"; echo psta-00beef > "$RUN/$mac/iface"
echo 02:00:00:00:00:20 > "$RUN/bssid"
backhaul() { echo phy1-sta0; }
iw() { printf 'Connected to 02:00:00:00:00:20 (on phy1-sta0)\n\tfreq: 5660.0\n'; }
bridge() { :; }
elect() { :; }
log() { echo "log $*"; }
kill() { echo "kill $*"; }
psta_supplicants() { printf '555 psta-00beef\n777 psta-00dead\n'; }
check "sweep kills an unclaimed supplicant" "kill 777
log killed orphan wpa_supplicant 777 on psta-00dead" "$(sweep)"
rm -rf "$RUN"
unset -f backhaul iw bridge elect log psta_supplicants
PSTAD_LIB=1 . ./pstad

# locked() must release its lock fd itself, and must not leak it to a
# backgrounded child that outlives the locked call (the wpa_supplicant bug).
RUN=$(mktemp -d)
locked true
flock -n "$RUN/lock" true; check "locked releases" 0 $?

hold() { sleep 3 & }
locked hold
flock -n "$RUN/lock" true; check "locked leaks to background child" 1 $?
wait

hold2() { sleep 3 9>&- & }
locked hold2
flock -n "$RUN/lock" true; check "locked with fd 9 closed" 0 $?
wait
rm -rf "$RUN" "$PROC"

exit $fail
