#!/usr/bin/env bash
set -euo pipefail

echo "Opening latest Firezone client log..."
latest_log=$(find ~/Library/Group\ Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/app -name "*.log" -print0 2>/dev/null | xargs -0 ls -t | head -1)
if [ -n "$latest_log" ]; then
    less "$latest_log"
else
    echo "No log files found"
fi
