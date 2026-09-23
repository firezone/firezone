# Fuzzing

## Targets

- `ip-packet`: parses and mutates a single IP packet through its API.
- `relay-proto`: drives the relay's message handling with arbitrary datagrams, repairing the nonce and HMAC on request so the authenticated path is reachable.
- `tunnel-proto`: drives the connlib tunnel state machine with a reference model and system-under-test harness.
- `x509-claims`: parses arbitrary DER as a client identity certificate and exercises everything derived from it.

[targets.json](targets.json) drives both pull-request CI and the nightly discovery matrix.
The single `fuzz` executable selects a target with its first argument; each target retains its own corpus and coverage ceiling.

## Execution

[AFL++](https://github.com/AFLplusplus/AFLplusplus) discovers inputs with a forkserver and one input per child (`AFL_FUZZER_LOOPCOUNT=1`).
Every child inherits the same parent memory, so buffer-pool, RNG, and hash-map state from an earlier input cannot affect the next input.
The entry point initializes the RNGs and shared clock anchor before starting the forkserver, including the subsecond offset that affects timer comparisons.
Separate parent processes can still start with different clock anchors.
This does not rewind external state such as the wall clock.

Corpus replay and source-coverage measurement use an ordinary optimized Rust binary and execute batches of inputs in one process.
This avoids both fork overhead and AFL's coverage-feedback instrumentation on the CI path where no inputs are selected or mutated.
The same target function and assertions run in both modes.
Persistent replay can retain state between inputs, so it does not establish discovery determinism.
Replay calls the target directly so any failing input fails the command and each completed batch exits normally to flush its LLVM profile.

## Setup

The pinned nightly toolchain, `cargo-afl`, and build settings live in [mise.toml](mise.toml).
Install that nightly with `rustup` before running `mise install --cd rust/tests/fuzz`, because installing `cargo-afl` compiles Rust code.
A C compiler and `make` are required to build the bundled AFL++ tools; the workflow's Ubuntu runners provide them.
CI caches the AFL++ tools and runtime in `~/.local/share/afl.rs` separately from mise's tool cache.
On a cache miss, CI reinstalls `cargo-afl` through mise to populate that directory.
These tasks target x86-64 Linux.
Discovery disables core files and skips the CPU-governor check.
AFL++ requires a `kernel.core_pattern` that does not pipe crashes to an external reporter; the nightly workflow configures this on its disposable runner.
For local discovery, follow AFL++'s startup diagnostic to configure crash reporting explicitly; replay needs no host configuration.

## Corpora

Each corpus is committed as a deterministic archive under `corpora/<target>.tar.gz`.
`unpack-corpus` materializes the archive into the ignored `corpus/<target>` directory.
`fuzz` and `replay` unpack first; `cmin` and `coverage` use the working corpus as it stands.

AFL++ keeps discoveries and crashes in `afl-output/<target>/<worker>/`.
The discovery task imports queue entries into the corpus by content hash and copies crashes and hangs into `artifacts/<target>`, including when interrupted.
Running discovery again resumes the existing worker queues.
Remove `afl-output/<target>` to start a new campaign after rebuilding a substantially changed target.

`cmin` uses `cargo afl cmin -e` to retain a set of inputs covering the observed union of AFL edges.
Inputs that differ only in edge hit counts do not add coverage for minimization.
This is edge coverage, not LLVM source-region coverage, so the two measurements need not select the same minimal set.
The original corpus is replaced only after minimization succeeds.
Discovery still uses hit counts to notice progress within loops.

Tunnel inputs are decoded positionally with `arbitrary::Unstructured`.
Changing the generators in [src/arb](src/arb) can reinterpret existing inputs; dispatch the nightly workflow to grow and minimize the corpus after such changes.

## Discovery and replay

```console
mise run //rust/tests/fuzz:fuzz ip-packet
mise run //rust/tests/fuzz:fuzz tunnel-proto --workers 4 --seconds 1800
mise run //rust/tests/fuzz:replay tunnel-proto
mise run //rust/tests/fuzz:replay ip-packet --repeat 100
```

Extra discovery arguments are passed to every AFL++ worker.
`tunnel-proto` and `relay-proto` allow inputs up to 8192 bytes; the other targets use 4096 bytes.
The default per-input timeout is 10 seconds.
Workers synchronize their queues and continue after finding a crash.
Their logs and `fuzzer_stats` remain in `afl-output/<target>`.

Replay preloads and sorts the corpus, then reports completed iterations and iterations per second, excluding loading and compilation time.
`--repeat` repeats the entire corpus in the same process.
Builds use separate `rust/target/afl`, `rust/target/fuzz-replay`, and `rust/target/fuzz-coverage` directories; `FUZZ_TARGET_DIR` overrides their parent directory.
Each build produces a `fuzz` executable, invoked as `fuzz <target>` for discovery or `fuzz <target> --replay <paths>...` for replay.

## Reproducing a crash

```console
mise run //rust/tests/fuzz:replay-crashes tunnel-proto
mise run //rust/tests/fuzz:tmin tunnel-proto artifacts/tunnel-proto/crashes-<hash>
mise run //rust/tests/fuzz:repro tunnel-proto artifacts/tunnel-proto/crashes-<hash>.minimized
```

`tmin` writes `<testcase>.minimized` and preserves the original input.
`repro` and `replay-crashes` enable debug tracing; set `RUST_LOG=trace` for more detail.
`save-crashes` copies up to ten failures into the corpus so pull-request replay keeps failing until the underlying bug is fixed.
All discovered originals remain in `artifacts`.

## Coverage and CI

```console
mise run //rust/tests/fuzz:unpack-corpus ip-packet
mise run //rust/tests/fuzz:coverage ip-packet
mise run //rust/tests/fuzz:coverage-check ip-packet
mise run //rust/tests/fuzz:coverage-report ip-packet
```

Pull-request CI only replays committed inputs and checks the existing uncovered-region ceiling.
Coverage replay uses up to one worker per 100 inputs, capped by available CPUs; set `FUZZ_REPLAY_WORKERS=1` for a single worker.
An increase in covered regions passes without updating that ceiling.
An increase in uncovered regions fails.
Coverage includes the selected crate, its workspace dependencies, and its test harness.
The tunnel target also includes the simulation library.
A failing replay identifies the input and does not replace the previous profile.

The [nightly workflow](../../../.github/workflows/fuzz-nightly.yml) runs parallel AFL++ workers for 30 minutes per target, minimizes the combined corpus, measures source coverage, refreshes the ceiling, then adds crashes and packs the corpus.
Each phase has its own timeout; completed findings survive failures in later phases.
On the default branch it opens a corpus PR per target and seeds subsequent runs from that PR as well as the default branch.
Dispatching on another branch pushes the resulting corpora and ceilings back to that branch.
The optional `target` workflow input limits the run to one target.

Use that workflow for corpus growth and baseline updates.
The `grow` task composes the same phases for environments without workflow access, defaults to three quarters of available cores, and accepts `--workers` and `--seconds` overrides.
