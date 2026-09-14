# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Purpose

`pstad` is a POSIX sh daemon for OpenWrt repeaters. For each allowlisted
client behind the repeater it creates a managed interface on the backhaul phy
with the client's MAC, runs a `wpa_supplicant` on it pinned to the backhaul's
BSSID, and installs `tc` flower rules that redirect the client's frames between
its bridge port and that station. It replaces relayd, which cannot coexist with
it. The design is in [docs/architecture.md](docs/architecture.md).

## Files

| File | Purpose |
|---|---|
| `pstad` | The daemon: `monitor`, `sweep`, `teardown-all`, `status` |
| `pstad.init` | procd init script running the monitor and sweep instances |
| `install.sh` | Installs packages and the two files onto a repeater over SSH |
| `tests/test-pstad.sh` | Unit tests; sources `pstad` with `PSTAD_LIB=1` and stubs device commands |
| `tests/tc-stats.txt` | Fixture: `tc -s filter show` output for the counter parser |
| `docs/quickstart.md` | Prerequisites, install, allowlist, verify |
| `docs/user-manual.md` | Every command, env knob, allowlist format, ImageBuilder overlay |
| `docs/architecture.md` | Why a station cannot bridge, the option space, the rule set |
| `docs/development.md` | Layout, running tests, the stubbing scheme, traps |
| `docs/backlog.md` | Outstanding work |

## Conventions

- `pstad`, `pstad.init` and `install.sh` are the deployed artefacts. Changing
  their behaviour needs a test in `tests/test-pstad.sh` and a matching doc
  change in the same commit.
- Comments in code say why, never what.
- Do not number section headings. No em-dashes in prose. No changelog file;
  git history is the record.
- Deferred work goes in `docs/backlog.md`, not in code comments.

## Tests

```sh
sh tests/test-pstad.sh
```

Needs `sh` and `flock`. No device access; every command that would touch a
radio, bridge or qdisc is replaced by a shell function inside the test.
