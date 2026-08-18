#!/usr/bin/env bash
#MISE description="Reduce a crashing input of a fuzz target"
#MISE depends=["install-toolchain"]
#MISE raw=true
#USAGE arg "<target>"
#USAGE arg "<testcase>"
set -euo pipefail
cd "$(dirname "$0")/.."

./interruptible.sh cargo fuzz tmin --sanitizer none --target x86_64-unknown-linux-gnu --fuzz-dir . --target-dir ../../target "${usage_target:?}" "${usage_testcase:?}"
