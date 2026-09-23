#!/usr/bin/env bash
#MISE description="Replay all crash artifacts for a fuzz target with tracing"
#MISE depends=["install-toolchain"]
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
# shellcheck source=../helpers.sh
source ./helpers.sh
collect_findings crashes
build_replay
shopt -s nullglob
for artifact in "artifacts/$target"/crashes-* "artifacts/$target"/hangs-*; do
    echo "::group::Scenario for ${artifact##*/}"
    RUST_LOG="${RUST_LOG:-debug}" "$replay_binary" --replay "$artifact" || true
    echo "::endgroup::"
done
