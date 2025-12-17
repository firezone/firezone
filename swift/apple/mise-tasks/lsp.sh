#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

if command -v xcode-build-server >/dev/null 2>&1; then
    xcode-build-server config \
        -project Firezone.xcodeproj \
        -scheme Firezone
else
    echo "xcode-build-server not installed, skipping LSP configuration"
    echo "   Install with: brew install xcode-build-server"
fi
