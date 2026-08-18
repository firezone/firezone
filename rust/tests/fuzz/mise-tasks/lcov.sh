#!/usr/bin/env bash
#MISE description="Export an existing fuzz coverage profile as lcov, restricted to our own sources"
#MISE depends=["install-toolchain"]
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"
profile="coverage/$target/coverage.profdata"
binary="../../target/x86_64-unknown-linux-gnu/release/$target"
llvm_cov="$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-cov"

if [ ! -f "$profile" ]; then
    echo "error: coverage profile is missing; run mise run //rust/tests/fuzz:coverage $target first" >&2
    exit 1
fi

# Fuzz builds instrument every dependency, including a from-source standard
# library. Their regions would otherwise dominate what we report to Coveralls.
"$llvm_cov" export \
    -format=lcov \
    -instr-profile="$profile" \
    -ignore-filename-regex="^${CARGO_HOME:-$HOME/.cargo}/" \
    -ignore-filename-regex="^${RUSTUP_HOME:-$HOME/.rustup}/" \
    "$binary"
