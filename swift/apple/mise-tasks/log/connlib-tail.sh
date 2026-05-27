#!/usr/bin/env bash
set -euo pipefail

echo "Following connlib log (requires sudo)..."
if [ -r "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/connlib.latest" ]; then
    exec tail -f "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/connlib.latest"
else
    exec sudo tail -f "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/connlib.latest"
fi
