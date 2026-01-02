#!/usr/bin/env bash
set -euo pipefail

echo "Following latest tunnel log (requires sudo)..."
latest_log=$(sudo find "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/tunnel" -name "*.jsonl" -print0 2>/dev/null | xargs -0 ls -t | head -1)
if [ -n "$latest_log" ]; then
    exec sudo tail -f "$latest_log"
else
    echo "No tunnel log files found"
fi
