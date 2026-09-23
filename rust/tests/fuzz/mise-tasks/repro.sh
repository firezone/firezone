#!/usr/bin/env bash
#MISE description="Replay one fuzz input with tracing; override RUST_LOG for more detail"
#MISE depends=["install-toolchain"]
#MISE raw=true
#USAGE arg "<target>"
#USAGE arg "<testcase>"
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
# shellcheck source=../helpers.sh
source ./helpers.sh
build_replay
RUST_LOG="${RUST_LOG:-debug}" "$replay_binary" --replay "${usage_testcase:?}"
