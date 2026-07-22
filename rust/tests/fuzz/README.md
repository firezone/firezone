# Fuzzing

## Targets

- `ip_packet` — parses and mutates a single IP packet through `ip-packet`'s API.
- `tunnel` — drives the connlib tunnel state machine. Each input is decoded
  positionally through `arbitrary::Unstructured` into one run of the
  reference-model / system-under-test harness (see
  `tunnel_tests::run_fuzz_case_structured`).

## Corpus

`corpus/tunnel` is committed to the repository. It is the regression suite for
the tunnel state machine: CI replays every input (crashes fail the build) and
enforces a region-coverage threshold on `tunnel-proto` (see the `tunnel-test`
job in `_rust.yml`). The nightly `fuzz-nightly.yml` workflow fuzzes longer,
minimizes the corpus with `cmin`, and opens a bot PR with the grown corpus;
merging it ratchets the coverage threshold up.

Because inputs are decoded positionally, changing the decision layout in
`arb.rs` re-interprets existing inputs. Coverage degrades gracefully rather
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

For the `tunnel` target, allow long inputs so deep scenarios stay reachable:

```
mise run //rust/tests/fuzz:fuzz tunnel -fork=4 -max_len=8192 -len_control=0
```

## Reproducing a crash

A crash writes the offending input to `artifacts/tunnel/`. To triage it:

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

1. Replay the corpus under instrumentation (writes
   `coverage/tunnel/coverage.profdata`):

   ```
   mise run //rust/tests/fuzz:coverage tunnel
   ```

1. Post-process the profdata with the `llvm-cov` task, e.g. the `tunnel-proto`
   region coverage as enforced by CI (paths are relative to this directory):

   ```
   mise run -q //rust/tests/fuzz:llvm-cov -- export -instr-profile=coverage/tunnel/coverage.profdata ../../target/x86_64-unknown-linux-gnu/release/tunnel | jq '[.data[].files[] | select(.filename | contains("libs/connlib/tunnel-proto/src/")) | .summary.regions] | (map(.covered) | add) / (map(.count) | add) * 100'
   ```

1. For a browsable HTML report, use `llvm-cov show` with the profdata and the
   rebuilt target at `../../target/x86_64-unknown-linux-gnu/release/tunnel`.
