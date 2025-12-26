#!/usr/bin/env bash
set -euo pipefail

echo "Showing Firezone Network Extension logs from system console (last 30 minutes)..."
log show --predicate 'process CONTAINS "dev.firezone.firezone.network-extension" OR (subsystem CONTAINS "dev.firezone" AND process != "Firezone")' --last 30m | less
