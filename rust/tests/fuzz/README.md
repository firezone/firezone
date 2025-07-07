# Fuzzing

## Setup

1. Install `cargo-fuzz`
1. Install `cargo-llvm-cov` (if you want to see coverage statistics)
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

## Coverage

1. Clean workspace
   ```
   cargo +nightly llvm-cov clean --workspace
   ```

1. Generate coverage profile
   ```
   cargo +nightly fuzz coverage --fuzz-dir tests/fuzz --target-dir ./target ip_packet
   ```

1. Copy profile data to place where `cargo-llvm-cov` can find it
   ```
   cp tests/fuzz/coverage/**/*.profraw ./target
   ```

1. Generate coverage report
   ```
   cargo +nightly llvm-cov report --html --release --target x86_64-unknown-linux-gnu
   ```
