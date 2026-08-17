#!/usr/bin/env bash
#MISE description="Minimize the corpus of a fuzz target"
#MISE depends=["install-toolchain", "unpack-corpus {{usage.target}}"]
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

./interruptible.sh cargo fuzz cmin --sanitizer none --target x86_64-unknown-linux-gnu --fuzz-dir . --target-dir ../../target "${usage_target:?}"
