#!/usr/bin/env bash
#MISE description="CLI smoke tests — tunnel (requires token + system extension)"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
CONFIGURATION="${CONFIGURATION:-Debug}"
TIMEOUT=20

cd "${APPLE_DIR}"

# Locate the CLI binary via xcodebuild
xcodebuild_output=$(xcodebuild -project Firezone.xcodeproj -scheme Firezone -configuration "${CONFIGURATION}" -showBuildSettings 2>&1) || {
    echo "Error: xcodebuild failed:" >&2
    echo "$xcodebuild_output" >&2
    exit 1
}
PRODUCTS_DIR=$(echo "$xcodebuild_output" | grep ' BUILT_PRODUCTS_DIR = ' | sed 's/.*= //')
if [ -z "$PRODUCTS_DIR" ]; then
    echo "Error: Could not determine build products directory" >&2
    exit 1
fi

CLI_PATH="$PRODUCTS_DIR/Firezone.app/Contents/MacOS/firezone"
if [ ! -x "$CLI_PATH" ]; then
    echo "Error: firezone CLI not found at $CLI_PATH" >&2
    echo "Run 'mise run //swift/apple:build' first." >&2
    exit 1
fi

echo "Testing: firezone --exit (${TIMEOUT}s timeout)"
echo "CLI: $CLI_PATH"
echo "---"

exit_code=0
output=$(timeout "$TIMEOUT" "$CLI_PATH" --exit 2>&1) || exit_code=$?

if [ "$exit_code" -eq 0 ]; then
    echo "PASS: --exit connected and exited cleanly"
elif [ "$exit_code" -eq 124 ]; then
    echo "FAIL: --exit timed out after ${TIMEOUT}s (tunnel did not connect)"
    echo "  Output: $output"
    exit 1
else
    echo "FAIL: --exit exited with code $exit_code"
    echo "  Output: $output"
    exit 1
fi
