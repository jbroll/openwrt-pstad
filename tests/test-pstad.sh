#!/bin/sh
# Run from anywhere: sh tests/test-pstad.sh
cd "$(dirname "$0")/.." || exit 1
PSTAD_LIB=1 . ./pstad
fail=0
check() {  # name expected actual
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi
}

mac=02:00:00:00:be:ef
check "fdb wired"          "$mac lan1"     "$(fdb_learned "$mac dev lan1 master br-lan")"
check "fdb wireless vlan"  "$mac phy0-ap0" "$(fdb_learned "$mac dev phy0-ap0 vlan 1 master br-lan")"
check "fdb deleted"        ""              "$(fdb_learned "Deleted $mac dev lan1 master br-lan")"
check "fdb permanent"      ""              "$(fdb_learned "02:00:00:00:00:11 dev lan1 master br-lan permanent")"
check "fdb self"           ""              "$(fdb_learned "$mac dev lan1 self")"
fdb_learned "Deleted $mac dev lan1 master br-lan"; check "fdb deleted status" 1 $?

link='Connected to 02:00:00:00:00:20 (on phy1-sta0)
	SSID: example-ssid
	freq: 5660.0
	RX: 1 bytes (1 packets)'
check "link params"   "02:00:00:00:00:20 5660" "$(printf '%s\n' "$link" | link_params)"
check "link down"     ""                       "$(echo 'Not connected.' | link_params)"

check "sent pkts"  32            "$(sent_pkts < tests/tc-stats.txt)"
check "iface"      psta-00beef   "$(iface_for $mac)"
check "pref"       48979         "$(pref_for $mac)"
check "pref floor" 100           "$(pref_for 00:00:00:00:00:00)"

ALLOW=$(mktemp); printf '%s\n' "$mac" > "$ALLOW"
allowed "$mac";               check "allowed"     0 $?
allowed 00:11:22:33:44:55;    check "not allowed" 1 $?
ALLOW=/nonexistent; allowed "$mac"; check "no allowlist" 1 $?
ALLOW=$(mktemp); printf '*\n' > "$ALLOW"
allowed 00:11:22:33:44:55; check "wildcard proxies any" 0 $?

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

# sweep: counter moved -> stays; counter still for IDLE -> torn down
mkdir -p "$RUN/$mac"
echo lan1 > "$RUN/$mac/port"; echo 48979 > "$RUN/$mac/pref"
echo 02:00:00:00:00:20 > "$RUN/bssid"
backhaul() { echo phy1-sta0; }
iw() { printf 'Connected to 02:00:00:00:00:20 (on phy1-sta0)\n\tfreq: 5660.0\n'; }
tc() { case "$1" in -s) cat tests/tc-stats.txt;; esac; }
echo 10 > "$RUN/$mac/count"; echo $(( $(date +%s) - 400 )) > "$RUN/$mac/seen"
check "sweep counter moved" ""              "$(sweep)"
check "sweep count updated" 32              "$(cat "$RUN/$mac/count")"
echo $(( $(date +%s) - 400 )) > "$RUN/$mac/seen"
check "sweep idle"          "teardown $mac" "$(sweep)"
mkdir -p "$RUN/$mac"; echo lan1 > "$RUN/$mac/port"; echo 48979 > "$RUN/$mac/pref"
echo 32 > "$RUN/$mac/count"; date +%s > "$RUN/$mac/seen"
iw() { printf 'Connected to 02:00:00:00:00:21 (on phy1-sta0)\n\tfreq: 5220.0\n'; }
write_conf() { echo "write_conf"; }
check "sweep backhaul moved" "teardown $mac
write_conf"                                "$(sweep)"
rm -rf "$RUN"

# Reset to the real setup/teardown/teardown_all/write_conf, undoing the
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

# teardown_all: one tc qdisc del per port that appeared, wpa.conf gone, returns 0
RUN=$(mktemp -d); CONF=$RUN/wpa.conf
mkdir -p "$RUN/mac1" "$RUN/mac2"
printf 'ifaceA\n' > "$RUN/mac1/iface"; printf 'lan1\n' > "$RUN/mac1/port"; printf '101\n' > "$RUN/mac1/pref"
printf 'ifaceB\n' > "$RUN/mac2/iface"; printf 'phy0-ap0\n' > "$RUN/mac2/port"; printf '102\n' > "$RUN/mac2/pref"
: > "$CONF"
iw() { :; }
tc() { echo "tc $*"; }
backhaul() { echo phy1-sta0; }
out=$(teardown_all)
echo "$out" | grep -qxF 'tc qdisc del dev lan1 clsact'
check "teardown_all clears lan1 clsact" 0 $?
echo "$out" | grep -qxF 'tc qdisc del dev phy0-ap0 clsact'
check "teardown_all clears phy0-ap0 clsact" 0 $?
echo "$out" | grep -qxF 'tc filter del dev phy1-sta0 ingress pref 101'
check "teardown removes the backhaul drop" 0 $?
echo "$out" | grep -qxF 'tc qdisc del dev phy1-sta0 clsact'
check "teardown_all clears backhaul clsact" 0 $?
unset -f backhaul
[ -f "$CONF" ]; check "teardown_all removes wpa.conf" 1 $?
teardown_all; check "teardown_all returns 0 with no clients" 0 $?
rm -rf "$RUN"

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
group_seen=$(echo "$out" | grep -c "dst_mac 01:00:00:00:00:00/01:00:00:00:00:00 action mirred egress redirect dev lan1")
check "setup passes group frames down to the port" 1 "$group_seen"
relayd_drop=$(echo "$out" | grep -n "dev psta-00beef ingress pref 3 protocol all flower src_mac 02:00:00:00:00:10 action drop" | cut -d: -f1)
group_line=$(echo "$out" | grep -n "pref 4 protocol all flower dst_mac 01:00" | cut -d: -f1)
[ -n "$relayd_drop" ] && [ -n "$group_line" ] && [ "$relayd_drop" -lt "$group_line" ]
check "setup drops relayd's upstream copies before passing group frames" 0 $?
drop_seen=$(echo "$out" | grep -c "dev phy1-sta0 ingress .* action drop")
check "setup adds no backhaul drop without assoc" 0 "$drop_seen"

# setup with an associating station: the backhaul drop lands before the port redirect
mkdir -p "$RUN"; echo 02:00:00:00:00:20 > "$RUN/bssid"
iw() { case "$*" in *link*) echo 'Connected to 02:00:00:00:00:20';; esac; }
out=$(setup "$mac" lan1)
drop_line=$(echo "$out" | grep -n "dev phy1-sta0 ingress pref 48979 protocol all flower src_mac $mac action drop" | cut -d: -f1)
redirect_line=$(echo "$out" | grep -n "dev lan1 ingress pref 48979 protocol all flower src_mac $mac action mirred" | cut -d: -f1)
[ -n "$drop_line" ] && [ -n "$redirect_line" ] && [ "$drop_line" -lt "$redirect_line" ]
check "setup drops the client's backhaul echo before redirecting" 0 $?
rm -rf "$RUN"
unset -f backhaul backhaul_mac phy_of ip wpa_supplicant iw sleep log teardown

# sweep: a station read Not connected once gets a grace period, not an immediate teardown
RUN=$(mktemp -d); d=$RUN/$mac
mkdir -p "$d"
echo lan1 > "$d/port"; echo 48979 > "$d/pref"
echo 0 > "$d/count"; date +%s > "$d/seen"
echo psta-00beef > "$d/iface"
echo 02:00:00:00:00:20 > "$RUN/bssid"
backhaul() { echo phy1-sta0; }
bridge() { :; }
teardown() { echo "teardown $1"; rm -rf "$RUN/$1"; }
log() { :; }
iw() { case "$2" in phy1-sta0) printf 'Connected to 02:00:00:00:00:20 (on phy1-sta0)\n\tfreq: 5660.0\n';; *) echo 'Not connected.';; esac; }
check "sweep grace period no immediate teardown" "" "$(sweep)"
[ -f "$d/down" ]; check "sweep grace period creates down marker" 0 $?

echo $(( $(date +%s) - 200 )) > "$d/down"
check "sweep grace period expired tears down" "teardown $mac" "$(sweep)"
rm -rf "$RUN"

# sweep: a station seen connected again clears the down marker without tearing down
RUN=$(mktemp -d); d=$RUN/$mac
mkdir -p "$d"
echo lan1 > "$d/port"; echo 48979 > "$d/pref"
echo 0 > "$d/count"; date +%s > "$d/seen"
echo psta-00beef > "$d/iface"
echo $(( $(date +%s) - 200 )) > "$d/down"
echo 02:00:00:00:00:20 > "$RUN/bssid"
iw() { printf 'Connected to 02:00:00:00:00:20 (on phy1-sta0)\n\tfreq: 5660.0\n'; }
check "sweep reconnect clears down marker" "" "$(sweep)"
[ -f "$d/down" ]; check "sweep reconnect removes down marker" 1 $?
rm -rf "$RUN"
unset -f log teardown backhaul bridge iw

# sweep tears down a client whose station has dropped off the backhaul
RUN=$(mktemp -d)
mkdir -p "$RUN/$mac"
echo lan1 > "$RUN/$mac/port"; echo 48979 > "$RUN/$mac/pref"
echo 0 > "$RUN/$mac/count"; date +%s > "$RUN/$mac/seen"
echo psta-00beef > "$RUN/$mac/iface"
echo 02:00:00:00:00:20 > "$RUN/bssid"
backhaul() { echo phy1-sta0; }
bridge() { :; }
teardown() { echo "teardown $1"; rm -rf "$RUN/$1"; }
log() { :; }
# The backhaul is up; only the client's own station is down, and its grace
# period has already elapsed.
echo $(( $(date +%s) - 200 )) > "$RUN/$mac/down"
iw() { case "$2" in phy1-sta0) printf 'Connected to 02:00:00:00:00:20 (on phy1-sta0)\n\tfreq: 5660.0\n';; *) echo 'Not connected.';; esac; }
check "sweep drops unassociated station" "teardown $mac" "$(sweep)"
rm -rf "$RUN"
unset -f log teardown

# sweep skips a directory missing seen, without touching anything
RUN=$(mktemp -d)
mkdir -p "$RUN/$mac"
echo lan1 > "$RUN/$mac/port"; echo 48979 > "$RUN/$mac/pref"; echo 0 > "$RUN/$mac/count"
echo 02:00:00:00:00:20 > "$RUN/bssid"
backhaul() { echo phy1-sta0; }
iw() { printf 'Connected to 02:00:00:00:00:20 (on phy1-sta0)\n\tfreq: 5660.0\n'; }
bridge() { :; }
check "sweep skips dir missing seen" "" "$(sweep)"
rm -rf "$RUN"

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
rm -rf "$RUN"

exit $fail
