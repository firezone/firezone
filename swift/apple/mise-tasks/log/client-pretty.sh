#!/usr/bin/env bash
set -euo pipefail

echo "Opening latest Firezone client log (formatted)..."
latest_log=$(find ~/Library/Group\ Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/app -name "*.jsonl" -print0 2>/dev/null | xargs -0 ls -t | head -1)
if [ -n "$latest_log" ]; then
    jq -r '[.timestamp, .level, .message] | @tsv' "$latest_log" | less
else
    echo "No log files found"
fi
