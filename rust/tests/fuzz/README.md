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
enforces a region-coverage threshold on `tunnel-proto` via
`check_coverage.py`. The nightly `fuzz-nightly.yml` workflow fuzzes longer,
minimizes the corpus with `cmin`, and uploads the result as an artifact;
commit that artifact to grow the corpus and ratchet the threshold up.

Because inputs are decoded positionally, changing the decision layout in
`arb.rs` re-interprets existing inputs. Coverage degrades gracefully rather
than breaking (the decoder is total), but after larger generator changes the
corpus should be re-minimized and re-grown via the nightly job.

## Setup

1. Install `cargo-fuzz`
1. Temporarily disable LTO (fuzzing won't work otherwise):
   ```
   export CARGO_PROFILE_RELEASE_LTO=false
   ```

## Run

Runs the fuzzer for the `ip_packet` fuzz target.
Substitute that for other targets that you want to run.

```
cargo +nightly fuzz run --fuzz-dir tests/fuzz --target-dir ./target ip_packet
```

For the `tunnel` target, allow long inputs so deep scenarios stay reachable:

```
cargo +nightly fuzz run --fuzz-dir tests/fuzz --target-dir ./target tunnel -- -fork=4 -max_len=8192 -len_control=0
```

## Reproducing a crash

A crash writes the offending input to `artifacts/tunnel/`. To triage it:

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

1. Replay the corpus under instrumentation (writes
   `coverage/tunnel/coverage.profdata`):

   ```
   cargo +nightly fuzz coverage --fuzz-dir tests/fuzz --target-dir ./target tunnel
   ```

1. Check the `tunnel-proto` region coverage against a threshold:

   ```
   python3 tests/fuzz/check_coverage.py 68
   ```

1. For a browsable HTML report, use `llvm-cov show` from the nightly
   toolchain's `llvm-tools-preview` with the profdata and the rebuilt target
   at `target/x86_64-unknown-linux-gnu/release/tunnel`.
