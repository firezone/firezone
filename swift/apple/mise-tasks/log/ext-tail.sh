#!/usr/bin/env bash
set -euo pipefail

echo "Following Firezone Network Extension logs..."
exec log stream --predicate 'process CONTAINS "dev.firezone.firezone.network-extension" OR (subsystem CONTAINS "dev.firezone" AND process != "Firezone")'
