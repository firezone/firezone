# Fuzzing

## Targets

- `ip-packet` — parses and mutates a single IP packet through `ip-packet`'s API.

Every fuzz target is listed in `targets.json` and has the same name as the
crate whose coverage it tracks. This list drives both pull-request CI and the
nightly discovery matrix.

## Corpora

Each target's corpus is committed as one deterministic archive under
`corpora/<target>.tar.gz`. The mise tasks unpack it into the ignored
`corpus/<target>` directory before invoking `cargo-fuzz`. Pull-request CI only
replays these inputs, making fuzz regression and coverage checks deterministic.
It never performs random coverage discovery.

The nightly `fuzz-nightly.yml` workflow runs every target from `targets.json`
on `main`, minimizes and repacks the grown corpora, refreshes their coverage
baselines, and opens one bot PR with the results.

## Setup

Everything is managed through this directory's `mise.toml`: the pinned nightly
toolchain, `cargo-fuzz`, and the profile overrides required by fuzz builds.
Fuzzing tasks require Linux because `cargo-fuzz` is installed only for Linux.

## Run

Run a target locally; extra arguments are passed to libFuzzer:

```console
mise run //rust/tests/fuzz:fuzz ip-packet
mise run //rust/tests/fuzz:fuzz ip-packet -fork=4
```

## Reproducing a crash

A crash writes the offending input to `artifacts/tunnel/`. To triage it:

1. Replay every failure artifact from the preceding fuzz run through the
   already-built binary with tracing:

   ```
   mise run //rust/tests/fuzz:replay-crashes tunnel
   ```

1. Reduce it (libFuzzer test-case minimization; the positional decoder shrinks
   cleanly since dropping trailing bytes drops trailing transitions):

   ```
   cargo +nightly fuzz tmin --fuzz-dir tests/fuzz --target-dir ./target tunnel artifacts/tunnel/crash-<hash>
   ```

1. Replay the single input with tracing to see the scenario. The harness
   installs a stderr subscriber only when `RUST_LOG` is set (mass fuzzing runs
   silent), and logs one line per applied transition plus the connlib trace:

   ```
   RUST_LOG=debug cargo +nightly fuzz run --fuzz-dir tests/fuzz --target-dir ./target tunnel <reduced-input> 2> repro.log
   ```

   Or via mise: `mise run tunnel-fuzz-repro <reduced-input>` (set `RUST_LOG=trace` for more).

## Coverage

Replay a committed corpus and check its uncovered-region ceiling:

```console
mise run //rust/tests/fuzz:coverage ip-packet
mise run //rust/tests/fuzz:coverage-check ip-packet
```

Coverage growth passes without requiring a baseline update. An increase in
uncovered regions fails. After deliberately growing and minimizing a corpus,
refresh its baseline with:

```console
mise run //rust/tests/fuzz:pack-corpus ip-packet
mise run //rust/tests/fuzz:coverage ip-packet
mise run -q //rust/tests/fuzz:coverage-summary ip-packet > expected-coverage/ip-packet.json
```
