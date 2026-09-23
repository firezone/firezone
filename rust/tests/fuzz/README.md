# Fuzzing

One executable exercises four targets, each with its own corpus and coverage check:

- `ip-packet`: packet parsing and mutation.
- `relay-proto`: relay message handling, including authenticated requests.
- `tunnel-proto`: tunnel behavior checked against a reference model.
- `x509-claims`: certificate parsing and identity claims.

## Execution model

[AFL++](https://github.com/AFLplusplus/AFLplusplus) discovers inputs through a forkserver, running each input in a fresh child process.
Each parent initializes the same RNG seeds and simulation clock anchor, and children inherit that state.
In-memory state left by one input cannot affect another; external state is not reset.

Replay runs saved inputs in persistent batches for speed, using the same target functions and assertions as discovery.
Any failing input fails the replay.
Because replay retains process state between inputs, it checks regressions but does not establish discovery determinism.

## Corpora and coverage

Committed corpora serve as regression tests and starting points for further discovery.
Minimization retains inputs that contribute edge coverage; differences in execution counts alone do not justify retaining an input.
AFL edge coverage guides discovery and minimization, while LLVM source coverage measures how much of the code the corpus exercises.

Pull-request CI checks that discovery coverage is stable within and across forkservers, replays the committed corpora, and rejects increases in uncovered source regions.
The [nightly workflow](../../../.github/workflows/fuzz-nightly.yml) grows and minimizes corpora, refreshes coverage ceilings, and retains failing inputs for regression testing.
On the default branch it proposes corpus PRs; dispatching it on another branch pushes results back to that branch.
Use that workflow when changes require new inputs or coverage baselines, including changes to how the tunnel generator interprets existing inputs.

## Usage

The tasks support x86-64 Linux.
Install the tools declared in [mise.toml](mise.toml), then select a target:

```console
mise install --cd rust/tests/fuzz
mise run //rust/tests/fuzz:fuzz ip-packet
mise run //rust/tests/fuzz:replay ip-packet
mise run //rust/tests/fuzz:replay ip-packet --repeat 100
```

Discovery accepts `--workers` and `--seconds`; replay reports iterations per second.
For local discovery, follow AFL++'s startup diagnostics for host configuration.

To minimize and investigate a saved crash:

```console
mise run //rust/tests/fuzz:tmin tunnel-proto artifacts/tunnel-proto/crashes-<hash>
mise run //rust/tests/fuzz:repro tunnel-proto artifacts/tunnel-proto/crashes-<hash>.minimized
```

`repro` enables debug tracing; set `RUST_LOG=trace` for more detail.
