#!/usr/bin/env bash
# mise description="Run FirezoneCLI headless client"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
CONFIGURATION="${CONFIGURATION:-Debug}"

cd "${APPLE_DIR}"

echo "Finding build location..."
xcodebuild_output=$(xcodebuild -project Firezone.xcodeproj -scheme Firezone -configuration "${CONFIGURATION}" -showBuildSettings 2>&1) || {
    echo "Error: xcodebuild failed:"
    echo "$xcodebuild_output" >&2
    exit 1
}
PRODUCTS_DIR=$(echo "$xcodebuild_output" | grep ' BUILT_PRODUCTS_DIR = ' | sed 's/.*= //')
if [ -z "$PRODUCTS_DIR" ]; then
    echo "Error: Could not determine build products directory"
    exit 1
fi

CLI_PATH="$PRODUCTS_DIR/Firezone.app/Contents/MacOS/firezone"
if [ ! -x "$CLI_PATH" ]; then
    echo "Error: firezone CLI not found at $CLI_PATH"
    exit 1
fi

echo "Running: firezone $*"
echo "---"
exec "$CLI_PATH" "$@"
