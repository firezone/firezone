#!/usr/bin/env bash
#MISE description="Minimize the corpus of a fuzz target"
#MISE depends=["install-toolchain"]
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

# No `unpack-corpus`: this minimizes the corpus directory as it stands, which in
# `grow` is what `fuzz` just grew. Unpack first when starting from a fresh
# checkout.

./interruptible.sh cargo fuzz cmin --sanitizer none --target x86_64-unknown-linux-gnu --fuzz-dir . --target-dir ../../target "${usage_target:?}"
