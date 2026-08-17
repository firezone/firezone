#!/usr/bin/env bash
#MISE description="Replay a target's corpus and generate a browsable HTML coverage report"
#MISE depends=["coverage {{usage.target}}"]
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"
profile="coverage/$target/coverage.profdata"
binary="../../target/x86_64-unknown-linux-gnu/release/$target"
report_dir="coverage/$target/html"
llvm_cov="$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-cov"

"$llvm_cov" show --format=html --output-dir="$report_dir" --instr-profile="$profile" "$binary"
echo "Coverage report: $PWD/$report_dir/index.html"
