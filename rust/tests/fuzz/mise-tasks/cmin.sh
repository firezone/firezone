#!/usr/bin/env bash
#MISE description="Minimize the corpus of a fuzz target"
#MISE depends=["install-toolchain"]
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"

# Select on edges alone. With counters, an input that runs known edges a
# different number of times counts as new coverage and stays committed forever
# without llvm-cov ever seeing a difference. Fuzzing keeps them, because they
# are what makes progress inside a loop visible.
set -- -use_counters=0

# The merge truncates inputs to the length limit it is given, so it has to be
# the one the target executes them at.
if [ "$target" = "tunnel-proto" ] || [ "$target" = "relay-proto" ]; then
    set -- -max_len=8192 -len_control=0 "$@"
fi

./interruptible.sh cargo fuzz cmin --sanitizer none --target x86_64-unknown-linux-gnu --fuzz-dir . --target-dir ../../target "$target" -- "$@"
