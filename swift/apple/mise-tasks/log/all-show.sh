#!/usr/bin/env bash
set -euo pipefail

echo "Showing all Firezone logs from system console (last 30 minutes)..."
log show --predicate '(process CONTAINS "Firezone" OR subsystem CONTAINS "dev.firezone") AND process != "codebook-lsp"' --last 30m | less
