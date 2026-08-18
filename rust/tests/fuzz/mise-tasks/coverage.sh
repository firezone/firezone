#!/usr/bin/env bash
#MISE description="Replay the corpus of a fuzz target, producing coverage/<target>/coverage.profdata"
#MISE depends=["install-toolchain", "unpack-corpus {{usage.target}}"]
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

cargo fuzz coverage --sanitizer none --target x86_64-unknown-linux-gnu --fuzz-dir . --target-dir ../../target "${usage_target:?}"
