# Fuzzing

## Targets

- `ip-packet` — parses and mutates a single IP packet through `ip-packet`'s API.
- `tunnel-proto` — drives the connlib tunnel state machine with a reference model and system-under-test harness.

Every fuzz target is listed in `targets.json` and has the same name as the crate whose coverage it tracks.
This list drives both pull-request CI and the nightly discovery matrix.

## Corpora

Each target's corpus is committed as one deterministic archive under `corpora/<target>.tar.gz`.
The mise tasks unpack it into the ignored `corpus/<target>` directory before invoking `cargo-fuzz`.
Pull-request CI only replays these inputs, making fuzz regression and coverage checks deterministic.
It never performs random coverage discovery.

The nightly `fuzz-nightly.yml` workflow runs every target from `targets.json` on `main`, minimizes and repacks the grown corpora, refreshes their coverage baselines, and opens one bot PR with the results.

Tunnel inputs are decoded positionally with `arbitrary::Unstructured`.
Changing the generator in `src/arb/` can therefore reinterpret existing inputs; after a substantial generator change, re-minimize and grow the corpus before updating the archive.

## Setup

Everything is managed through this directory's `mise.toml`: the pinned nightly toolchain, `cargo-fuzz`, and the profile overrides required by fuzz builds.
Fuzzing tasks require Linux because `cargo-fuzz` is installed only for Linux.

## Run

Run a target locally; extra arguments are passed to libFuzzer:

```console
mise run //rust/tests/fuzz:fuzz ip-packet
mise run //rust/tests/fuzz:fuzz ip-packet -fork=4
mise run //rust/tests/fuzz:fuzz tunnel-proto -fork=4
```

`tunnel-proto` automatically uses `-max_len=8192 -len_control=0` so deep state-machine runs remain reachable.

## Reproducing a crash

```console
mise run //rust/tests/fuzz:replay-crashes tunnel-proto
mise run //rust/tests/fuzz:tmin tunnel-proto artifacts/tunnel-proto/crash-<hash>
mise run //rust/tests/fuzz:repro tunnel-proto <reduced-input> 2> repro.log
```

Set `RUST_LOG=trace` for detailed scenario and connlib traces.

## Coverage

Replay a committed corpus and check its uncovered-region ceiling:

```console
mise run //rust/tests/fuzz:coverage ip-packet
mise run //rust/tests/fuzz:coverage-check ip-packet
```

Coverage growth passes without requiring a baseline update.
An increase in uncovered regions fails.
After deliberately growing and minimizing a corpus, refresh its baseline with:

```console
mise run //rust/tests/fuzz:pack-corpus tunnel-proto
mise run //rust/tests/fuzz:coverage tunnel-proto
mise run -q //rust/tests/fuzz:coverage-summary tunnel-proto > expected-coverage/tunnel-proto.json
```

For a local browsable report:

```console
mise run //rust/tests/fuzz:coverage-report tunnel-proto
```
