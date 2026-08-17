#!/usr/bin/env bash
#MISE description="Replay one fuzz input with tracing; override RUST_LOG for more detail"
#MISE depends=["install-toolchain"]
#MISE raw=true
#USAGE arg "<target>"
#USAGE arg "<testcase>"
set -euo pipefail
cd "$(dirname "$0")/.."

RUST_LOG="${RUST_LOG:-debug}" cargo fuzz run --sanitizer none --target x86_64-unknown-linux-gnu --fuzz-dir . --target-dir ../../target "${usage_target:?}" "${usage_testcase:?}"
