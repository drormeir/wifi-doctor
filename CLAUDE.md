# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single self-contained Bash script (`wifi-doctor.sh`) that diagnoses the current
network connection **toward a chosen server** and prints `nmcli` commands or
in-the-moment actions to get through. It is **read-only**: it measures and suggests,
but never changes system state. The user runs the suggested commands themselves.

There is no build system, test suite, or linter. `README.md` is the user-facing guide;
`TECHNICAL_NOTES.md` records the design rationale and the non-obvious networking
lessons that justify each decision — read it before changing diagnostic logic.

## Running

Always invoke the script by an explicit path that points at **this repo's copy**, so a
different `wifi-doctor.sh` on `PATH` is never run by mistake. Use the absolute path to the
script in the project root (works for any user/clone location):

```sh
"$(git rev-parse --show-toplevel)/wifi-doctor.sh"              # interactive target menu
"$(git rev-parse --show-toplevel)/wifi-doctor.sh" <alias>     # e.g. pypi, claude, israel
"$(git rev-parse --show-toplevel)/wifi-doctor.sh" <url|host>  # any server you paste
"$(git rev-parse --show-toplevel)/wifi-doctor.sh" -l          # list targets and exit
```

(Or `./wifi-doctor.sh` when the working directory is the project root.) Run while
connected to the network being checked. It is interactive only when stdin is
a TTY; with no arg and no TTY it exits with guidance. Add targets by editing the
`TARGETS` block (`alias|description|url`); `__PYPI__` resolves to a live PyPI wheel.

## Architecture: the diagnostic pipeline

The script runs as a linear pipeline (numbered sections 0–4 in the source). Later stages
depend on verdicts from earlier ones:

0. **Choose target** → resolve to a URL, extract `HOST`, resolve its IPv4/IPv6.
1. **Identify connection** → device, NetworkManager connection name, interface MTU, and
   (Wi-Fi only) signal dBm/band. `MTU_KEY` is derived from connection type so the right
   nmcli property is suggested.
2. **Transfer test** (`run_dl` / `verdict`) → samples a capped HTTP-range download per
   address family, classifies each as `good|slow|reset|stalled|fail`.
3. **Path-MTU / loss analysis** (`pmtu_measure`) → DF-ping cliff search per family.
4. **Recommendations** → a chain of guarded `if` blocks, each gated on a specific
   symptom combination.

### Key design invariants (don't break these)

These are deliberate and counterintuitive; changing them reintroduces false positives
documented in `TECHNICAL_NOTES.md`:

- **Diagnose toward a specific server, never "the internet."** MTU, IPv6 health, loss and
  resets are properties of the route to a destination. The chosen target's own addresses
  drive every probe.
- **Verdicts come from curl exit codes + bytes/speed**, not from waiting for a full file
  (`verdict()`): `0`=good, `28`=slow-or-stalled (split by speed vs `STALL_RATE`),
  `18|56`=reset. `works()`/`broke()` collapse these into usable/failed.
- **The expensive MTU cliff search runs only when a transfer broke** (`need_cliff`).
  Otherwise just a cheap baseline-loss sample. Keep the common (healthy) case fast.
- **Cliff vs gradient distinguishes a real MTU limit from a lossy link.** High baseline
  small-packet loss → declare `lossy` and refuse to report an MTU number. A real MTU limit
  requires a sharp pass→fail transition (`PASS_LOSS`/`CLIFF_LOSS`/`BASE_LOSSY`).
- **Only recommend lowering MTU on a `stalled` transfer with a clean measured cliff** —
  the signature of broken PMTUD. A path MTU below 1500 is normal and harmless on its own;
  a clean reset (exit 56) is a carrier/server drop, not MTU.
- **Weak signal is layer-1 and family-agnostic** — it is handled first and never blamed
  for a per-family difference (e.g. IPv6 resets while IPv4 works). When signal is weak,
  give resource-free advice (move closer / resume-capable download), never "switch
  networks" (the user may not have another).
- **Every nmcli suggestion is per-connection and reversible** — the output always includes
  the undo commands and states that other networks are unaffected.

### Output / helpers

Colored status helpers (`ok`/`warn`/`bad`/`b`/`line`) write directly to the terminal.
`set -u` is on; tolerate missing tools and empty values with `${var:-}` and the
`command -v ... || ...` guards already used (e.g. `python3`, `ping`).
