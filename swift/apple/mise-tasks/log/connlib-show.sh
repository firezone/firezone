#!/usr/bin/env bash
set -euo pipefail

# The tunnel writes into its own group container. The standalone build's system
# extension runs as root, so its logs land under root's home; the App Store
# build's app extension runs as you, so they land under yours.
group_container="47R2M6779T.dev.firezone.firezone"
user_logs="${HOME}/Library/Group Containers/${group_container}/Library/Caches/logs"
root_logs="/private/var/root/Library/Group Containers/${group_container}/Library/Caches/logs"

echo "Viewing connlib log..."
if [ -r "${user_logs}/connlib/connlib.latest" ]; then
    less "${user_logs}/connlib/connlib.latest"
elif [ -r "${root_logs}/connlib/connlib.latest" ]; then
    less "${root_logs}/connlib/connlib.latest"
else
    sudo less "${root_logs}/connlib/connlib.latest"
fi
