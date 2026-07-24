# Fuzzing

## Targets

- `ip_packet` — parses and mutates a single IP packet through `ip-packet`'s API.
- `tunnel` — drives the connlib tunnel state machine. Each input is decoded
  positionally through `arbitrary::Unstructured` into one run of the
  reference-model / system-under-test harness.

## Corpus

`corpus/tunnel` is committed to the repository. It is the regression suite for
the tunnel state machine: CI replays every input (crashes fail the build) and
uses `expected-coverage.json` as a ceiling for the number of uncovered
`tunnel-proto` regions (see the `tunnel-test` job in `_rust.yml`). Coverage
growth passes without requiring a snapshot update; an increase in uncovered
regions fails and should be justified (or better, grow the corpus back). The
nightly `fuzz-nightly.yml` workflow fuzzes longer, minimizes the corpus with
`cmin`, and opens a bot PR with the grown corpus and the refreshed snapshot.

Because inputs are decoded positionally, changing the decision layout in
`src/arb/` re-interprets existing inputs. Coverage degrades gracefully rather
than breaking (the decoder is total), but after larger generator changes the
corpus should be re-minimized and re-grown via the nightly job.

## Setup

Everything is managed through `mise.toml` in this directory: the pinned
nightly toolchain, `cargo-fuzz`, and the profile overrides fuzzing needs
(LTO off, parallel codegen). There is nothing to install by hand.

## Run

Run a target via the `fuzz` task; extra arguments are passed to libFuzzer:

```
mise run //rust/tests/fuzz:fuzz ip_packet
```

The task automatically gives the `tunnel` target `-max_len=8192
-len_control=0`, so deep scenarios stay reachable without callers having to
remember the target-specific defaults:

```
mise run //rust/tests/fuzz:fuzz tunnel -fork=4
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
   mise run //rust/tests/fuzz:tmin tunnel artifacts/tunnel/crash-<hash>
   ```

1. Replay the single input with tracing to see the scenario. The harness
   installs a stderr subscriber only when `RUST_LOG` is set (mass fuzzing runs
   silent), and logs one line per applied transition plus the connlib trace:

   ```
   mise run //rust/tests/fuzz:repro tunnel <reduced-input> 2> repro.log
   ```

   Set `RUST_LOG=trace` for more detail.

## Coverage

1. Generate a browsable HTML report:

   ```
   mise run //rust/tests/fuzz:coverage-report tunnel
   ```

   The task prints the path to `coverage/tunnel/html/index.html`. To only replay
   the corpus and produce `coverage/tunnel/coverage.profdata`, use the
   `coverage` task instead.

1. Post-process that profdata with the `llvm-cov` task, e.g. the `tunnel-proto`
   region counts as pinned by CI (paths are relative to this directory; write
   the output to `expected-coverage.json` to update the snapshot):

   ```
   mise run -q //rust/tests/fuzz:llvm-cov -- export -instr-profile=coverage/tunnel/coverage.profdata ../../target/x86_64-unknown-linux-gnu/release/tunnel | jq '[.data[].files[] | select(.filename | contains("libs/connlib/tunnel-proto/src/")) | .summary.regions] | {covered: (map(.covered) | add), total: (map(.count) | add)}'
   ```
