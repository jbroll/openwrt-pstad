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

There is no build step. The deployed files are the ones in the repo root.

## Running the tests

```sh
sh tests/test-pstad.sh
```

Needs a POSIX `sh` and `flock` (util-linux). It prints one `ok` or `FAIL`
line per check and exits non-zero on any failure. Run it before every commit
that touches `pstad`.

## How the tests work

`pstad` ends its function definitions with

```sh
[ -n "$PSTAD_LIB" ] && return 0
```

before the `case "$1"` dispatch, so `PSTAD_LIB=1 . ./pstad` loads every
function into the calling shell without running anything. The test script does
that, then redefines whichever functions or commands would touch the device
(`iw`, `tc`, `ip`, `bridge`, `wpa_supplicant`, `kill`, `sleep`, `backhaul`,
`backhaul_mac`, `phy_of`, `log`, `setup`, `teardown`, `write_conf`) as shell
functions that print their arguments or return canned output. Because the
daemon calls these by bare name, a function shadows the real binary.

Each block sets up a temporary `RUN` directory, runs the function under test,
and compares its output or the resulting files. Stubs are removed with
`unset -f` at the end of a block, and the script re-sources `pstad` once in
the middle to restore `setup`, `teardown`, `teardown_all` and `write_conf`
after the lifecycle tests replaced them.

The `locked` tests use the real `flock`. They check that the lock is released
when the locked command returns, that a backgrounded child inheriting fd 9
keeps it held (the bug that motivated `9>&-` on the `wpa_supplicant` line),
and that closing fd 9 in the child fixes it.

The test MACs are locally-administered addresses (`02:...`). If you change
the client MAC, recompute the expected interface name (last six hex digits of
the MAC) and pref (low 16 bits of the MAC as an integer, mod 65000, plus 100)
and update `tests/tc-stats.txt` to match.

## Testing on a device

`pstad` writes nothing outside `$RUN`, so a manual run against a real repeater
can use a private state directory:

```sh
RUN=/tmp/psta-test ALLOW=/tmp/allow pstad monitor
```

Two instances of `pstad` on the same `RUN` serialise through `$RUN/lock`;
two on different `RUN` directories do not, and will fight over the same tc
prefs and interface names.

Do not clean up with `killall wpa_supplicant`. netifd runs its own
`wpa_supplicant` for the backhaul station and killing it takes the repeater's
wifi down with it. It comes back on its own within seconds, with new
ifindexes, but every proxy station goes with it. Kill by PID from
`$RUN/<mac>/pid`, or run `pstad teardown-all`.

## Style

POSIX sh only; the target is BusyBox ash. No bashisms, no arrays, no
`[[ ]]`. Comments say why, not what. Section headings in docs are not
numbered. No em-dashes.
