#!/usr/bin/env bash
set -euo pipefail

# The tunnel writes into its own group container. The standalone build's system
# extension runs as root, so its logs land under root's home; the App Store
# build's app extension runs as you, so they land under yours.
group_container="47R2M6779T.dev.firezone.firezone"
user_logs="${HOME}/Library/Group Containers/${group_container}/Library/Caches/logs"
root_logs="/private/var/root/Library/Group Containers/${group_container}/Library/Caches/logs"

# `set -e` would abort on a find that has no directory to search, so only look
# where there is something to look at.
newest_log() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    find "$dir" -name "*.log" -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1
}

echo "Following latest tunnel log..."
latest_log=$(newest_log "${user_logs}/tunnel")
if [ -n "$latest_log" ]; then
    exec tail -f "$latest_log"
fi

latest_log=$(sudo bash -c 'find "$1" -name "*.log" -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1' _ "${root_logs}/tunnel")
if [ -n "$latest_log" ]; then
    exec sudo tail -f "$latest_log"
else
    echo "No tunnel log files found"
fi
