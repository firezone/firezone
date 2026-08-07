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
An input that made the target fail is packed into the corpus with the rest, so the commit the workflow pushes is what reports the bug: the run itself stays green, and replaying that corpus turns CI red until the bug is fixed.

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

```console
mise run //rust/tests/fuzz:replay-crashes tunnel-proto
mise run //rust/tests/fuzz:tmin tunnel-proto artifacts/tunnel-proto/crash-<hash>
mise run //rust/tests/fuzz:repro tunnel-proto <reduced-input> 2> repro.log
```

Set `RUST_LOG=trace` for detailed scenario and connlib traces.

A fuzz job's findings arrive in the corpus instead, keeping the `crash-` name libFuzzer gave them.
`coverage` names the one it died on, and `repro` and `tmin` take that path like any other input.
Nothing needs pruning once the bug is fixed: the input stops failing and the next `cmin` re-emits it under its content hash, where it goes on covering the code that used to crash.
Until then the corpus cannot be minimized at all, since minimizing means running every input; `cargo-fuzz` reports the failed merge and leaves the corpus as it was.

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

When the ceiling is genuinely exceeded, `grow` runs the whole recovery locally: it fuzzes for new coverage, minimizes the corpus, refreshes the baseline from what the grown corpus actually reaches, then repacks it.

```console
mise run //rust/tests/fuzz:grow tunnel-proto
```

This runs what the nightly workflow runs, so commit both the repacked corpus and the refreshed baseline.
Expect it to take a while: it fuzzes for 30 minutes before the remaining steps even start.

It spreads that across three quarters of the cores, leaving you some to work with, and across all of them when `CI` is set.
Pass libFuzzer arguments to override both the parallelism and the duration, e.g. `-fork=8 -max_total_time=300`.
Be wary of shortening it much for `tunnel-proto`: `-fork` re-merges the whole seed corpus before it discovers anything, `-max_total_time` does not bound that startup, and a short budget is spent entirely inside it.

`grow` passes `-ignore_crashes=1`, so a crash no longer ends the run: it grinds for the whole budget and collects every input that fails, not just the first.
libFuzzer honours that in fork mode only, where it already ignores timeouts and OOMs.
Those inputs join the corpus once the coverage measurement is done, which is late enough that a crash cannot cost the run its refreshed ceiling.
A run adds at most ten of them: a bug the fuzzer reaches easily yields a distinct input on every hit, and one backtrace does not need hundreds of variations committed.

A failing step does not stop the ones behind it either; `grow` runs them all and reports the failure at the end.
Whichever step broke, the run still ends with a repacked corpus carrying what it found.

The measurement is taken on the machine that runs it.
A local run that gets luckier than CI writes a ceiling CI cannot meet, so re-run `coverage-check` before pushing.

After growing and minimizing a corpus yourself, the remaining steps run individually; `update-baseline` records the measurement without the risk of truncating the committed file on a failed one:

```console
mise run //rust/tests/fuzz:coverage tunnel-proto
mise run //rust/tests/fuzz:update-baseline tunnel-proto
mise run //rust/tests/fuzz:save-crashes tunnel-proto
mise run //rust/tests/fuzz:pack-corpus tunnel-proto
```

For a local browsable report:

```console
mise run //rust/tests/fuzz:coverage-report tunnel-proto
```
