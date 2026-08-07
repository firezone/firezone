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
A crash does not cost the run its findings: the workflow pushes the grown corpus either way and commits the input that provoked the crash alongside it.

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

A local run leaves its failing inputs in the ignored `artifacts/<target>` directory.
Inputs under `crashes/<target>` are committed instead: they are what a fuzz job found and had no chance to fix.
`replay-crashes` replays both, building the target first if nothing has yet.

```console
mise run //rust/tests/fuzz:replay-crashes tunnel-proto
mise run //rust/tests/fuzz:tmin tunnel-proto crashes/tunnel-proto/crash-<hash>
mise run //rust/tests/fuzz:repro tunnel-proto <reduced-input> 2> repro.log
```

Set `RUST_LOG=trace` for detailed scenario and connlib traces.

Delete a committed input in the change that fixes it.
Nothing else prunes them, and only the corpus guards against the bug coming back, so add the input there in the same change if it reaches code the corpus does not.

## Coverage

Replay a committed corpus and check its uncovered-region ceiling:

```console
mise run //rust/tests/fuzz:coverage ip-packet
mise run //rust/tests/fuzz:coverage-check ip-packet
```

Coverage growth passes without requiring a baseline update.
An increase in uncovered regions fails.

The ceiling spans every workspace crate the target links, not just the one sharing its name.
A fuzz build instruments the dependencies too, so a target that drives `tunnel-proto` reports what it reached in `snownet`, `dns-types` and the rest as one number.
Which lines a crate contributes is visible in the HTML coverage report.

When the ceiling is genuinely exceeded, `grow` runs the whole recovery locally: it fuzzes for new coverage, minimizes and repacks the corpus, then refreshes the baseline from what the grown corpus actually reaches.

```console
mise run //rust/tests/fuzz:grow tunnel-proto
```

This runs what the nightly workflow runs, so commit both the repacked corpus and the refreshed baseline.
Expect it to take a while: it fuzzes for 30 minutes before the remaining steps even start.

It spreads that across three quarters of the cores, leaving you some to work with, and across all of them when `CI` is set.
Pass libFuzzer arguments to override both the parallelism and the duration, e.g. `-fork=8 -max_total_time=300`.
Be wary of shortening it much for `tunnel-proto`: `-fork` re-merges the whole seed corpus before it discovers anything, `-max_total_time` does not bound that startup, and a short budget is spent entirely inside it.

A failing step does not stop the ones behind it; `grow` runs them all and reports the failure at the end.
A crash therefore still leaves a grown corpus behind, and moves the input that provoked it to `crashes/<target>` to be committed.

The measurement is taken on the machine that runs it.
A local run that gets luckier than CI writes a ceiling CI cannot meet, so re-run `coverage-check` before pushing.

After growing and minimizing a corpus yourself, the remaining steps run individually; `update-baseline` records the measurement without the risk of truncating the committed file on a failed one:

```console
mise run //rust/tests/fuzz:pack-corpus tunnel-proto
mise run //rust/tests/fuzz:coverage tunnel-proto
mise run //rust/tests/fuzz:update-baseline tunnel-proto
```

For a local browsable report:

```console
mise run //rust/tests/fuzz:coverage-report tunnel-proto
```
