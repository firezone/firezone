#!/usr/bin/env bash
set -euo pipefail

echo "Following all Firezone logs (including connlib from file)..."

# Trap to kill all children on exit
trap 'kill 0' INT TERM EXIT

# Stream console logs in background
log stream --predicate '(process CONTAINS "Firezone" OR subsystem CONTAINS "dev.firezone" OR category == "connlib") AND process != "codebook-lsp"' &

# Also tail connlib log file if accessible
if [ -r "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/latest" ]; then
    tail -f "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/latest" &
else
    echo "Note: connlib file logs require sudo access. Run 'mise run log:connlib-tail' with sudo for file logs."
fi

wait
