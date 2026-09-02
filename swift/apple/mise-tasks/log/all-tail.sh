#!/usr/bin/env bash
set -euo pipefail

# The tunnel writes into its own group container. The standalone build's system
# extension runs as root, so its logs land under root's home; the App Store
# build's app extension runs as you, so they land under yours.
group_container="47R2M6779T.dev.firezone.firezone"
user_logs="${HOME}/Library/Group Containers/${group_container}/Library/Caches/logs"
root_logs="/private/var/root/Library/Group Containers/${group_container}/Library/Caches/logs"

echo "Following all Firezone logs (including connlib from file)..."

# Trap to kill all children on exit
trap 'kill 0' INT TERM EXIT

# Stream console logs in background
log stream --predicate '(process CONTAINS "Firezone" OR subsystem CONTAINS "dev.firezone" OR category == "connlib") AND process != "codebook-lsp"' &

# Also tail connlib log file if accessible
if [ -r "${user_logs}/connlib/connlib.latest" ]; then
    tail -f "${user_logs}/connlib/connlib.latest" &
elif [ -r "${root_logs}/connlib/connlib.latest" ]; then
    tail -f "${root_logs}/connlib/connlib.latest" &
else
    echo "Note: connlib file logs require sudo access. Run 'mise run log:connlib-tail' with sudo for file logs."
fi

wait
