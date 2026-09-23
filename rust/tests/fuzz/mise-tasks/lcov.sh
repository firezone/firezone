#!/usr/bin/env bash
#MISE description="Export an existing fuzz coverage profile as lcov, restricted to our own sources"
#MISE depends=["install-toolchain"]
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"
profile="coverage/$target/coverage.profdata"
# shellcheck source=../helpers.sh
source ./helpers.sh
binary="$coverage_binary"
llvm_cov="$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-cov"

if [ ! -f "$profile" ]; then
    echo "error: coverage profile is missing; run mise run //rust/tests/fuzz:coverage $target first" >&2
    exit 1
fi

sources="$(coverage_sources)"
mapfile -t sources <<<"$sources"
"$llvm_cov" export \
    -format=lcov \
    -instr-profile="$profile" \
    "$binary" "${sources[@]}"
