# Development

## Layout

```
pstad                  the daemon, POSIX sh, one file
pstad.init             procd init script
install.sh             push pstad and pstad.init to a repeater over SSH
tests/test-pstad.sh    unit tests
tests/tc-stats.txt     fixture: tc -s filter show output
docs/                  this documentation
```

There is no build step. The files in the repo root are what gets deployed.

## Running the tests

```sh
sh tests/test-pstad.sh
```

Needs a POSIX `sh` and `flock` (util-linux). Prints `ok` or `FAIL` per check
and exits non-zero on any failure. Run it before every commit that touches
`pstad`.

## How the tests work

`pstad` stops before its command dispatch when `PSTAD_LIB` is set:

```sh
[ -n "$PSTAD_LIB" ] && return 0
```

so `PSTAD_LIB=1 . ./pstad` loads its functions without running anything. The
test script then redefines, as shell functions, the commands that would touch
the device (`iw`, `tc`, `ip`, `bridge`, `uci`, `wpa_supplicant`, `kill`,
`sleep`) and whichever `pstad` functions a block needs out of the way. A
function shadows a binary of the same name. `PROC` points at a temporary
directory for the whole run, so nothing reads the host's `/proc`. Blocks that
need a port to look wireless or bridged point `SYS` at a temporary directory
too.

Each block uses a temporary `RUN` directory, runs the function under test, and
checks its output or the files it leaves. Stubs are removed with `unset -f`,
and the script re-sources `pstad` wherever it needs the real functions back.

The `locked` tests use the real `flock`. They check that the lock is released
when the command returns, that a background child inheriting fd 9 keeps it
held, and that closing fd 9 in the child, as the `wpa_supplicant` line does,
releases it.

Test MACs are locally administered (`02:...`). Changing one means updating the
expected interface name, the last six hex digits of the MAC, and
`tests/tc-stats.txt`.

## Testing on a device

`pstad` writes nothing outside `$RUN`, so a manual run can use a private state
directory:

```sh
RUN=/tmp/psta-test ALLOW=/tmp/allow pstad monitor
```

Instances sharing a `RUN` serialise through `$RUN/lock`. Instances with
different `RUN` directories do not, and fight over the same prefs and
interface names.

Synthetic wired clients need no second device. With `kmod-veth` and `ip-full`,
put one end of a veth pair in the bridge and run `udhcpc` on the other, with a
script that sets only the address so it adds no default route. To count
broadcast copies, capture on the veth with `tcpdump -ni vt1 'icmp[icmptype]=8'`
and `ping -b` the LAN broadcast from upstream. One request per ping means one
forwarder. To exercise a departure, kick a wireless client:

```sh
ubus call hostapd.<ap iface> del_client '{"addr":"<mac>","reason":5,"deauth":true,"ban_time":0}'
```

Do not clean up with `killall wpa_supplicant`. netifd runs the backhaul's
supplicant, and killing it drops the repeater's wifi and every proxy station
with it. Use `pstad teardown-all`, or kill the one PID `ps w | grep psta-`
shows.

## Style

POSIX sh for BusyBox ash: no bashisms, arrays or `[[ ]]`. Comments say why,
not what. Doc headings are not numbered, and prose has no em-dashes.
