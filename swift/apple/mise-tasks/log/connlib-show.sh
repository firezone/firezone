#!/usr/bin/env bash
set -euo pipefail

echo "Viewing connlib log (requires sudo)..."
if [ -r "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/latest" ]; then
    less "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/latest"
else
    sudo less "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/latest"
fi
