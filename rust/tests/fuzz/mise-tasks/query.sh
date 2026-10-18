#!/usr/bin/env bash
#MISE description="Run an SQL query against a target's emitted JSON Lines"
#USAGE arg "<target>"
#USAGE arg "<query>"
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
views="sql/$target.sql"

if [ ! -f "$views" ] || [ ! -f "json/$target/inputs.jsonl" ]; then
    echo "error: no JSON for $target; run mise run //rust/tests/fuzz:emit-json $target first" >&2
    exit 1
fi

duckdb -init "$views" -c "${usage_query:?}"
