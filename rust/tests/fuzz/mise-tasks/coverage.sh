#!/usr/bin/env bash
#MISE description="Replay the corpus of a fuzz target, producing coverage/<target>/coverage.profdata"
#MISE depends=["install-toolchain"]
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

# No `unpack-corpus`: this replays the corpus directory as it stands, which in
# `grow` is what `cmin` just reduced. Unpack first when starting from a fresh
# checkout.

cargo fuzz coverage --sanitizer none --target x86_64-unknown-linux-gnu --fuzz-dir . --target-dir ../../target "${usage_target:?}"
