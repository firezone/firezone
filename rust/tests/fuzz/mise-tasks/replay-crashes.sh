#!/usr/bin/env bash
#MISE description="Replay all crash artifacts for a fuzz target with tracing"
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"
bin="../../target/x86_64-unknown-linux-gnu/release/$target"
found=false

for artifact in \
    "artifacts/$target"/crash-* \
    "artifacts/$target"/timeout-* \
    "artifacts/$target"/oom-* \
    "artifacts/$target"/leak-* \
    "artifacts/$target"/slow-unit-*; do
    [ -e "$artifact" ] || continue

    if [ "$found" = false ]; then
        if [ ! -x "$bin" ]; then
            echo "Fuzz target binary does not exist or is not executable: $bin" >&2
            exit 1
        fi
        found=true
    fi

    echo "::group::Scenario for ${artifact##*/}"
    RUST_LOG="${RUST_LOG:-debug}" "$bin" "$artifact" || true
    echo "::endgroup::"
done

if [ "$found" = false ]; then
    echo "No crash artifact was written; nothing to replay."
fi
