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

CLI_PATH="$PRODUCTS_DIR/Firezone.app/Contents/Helpers/firezone-cli.app/Contents/MacOS/firezone-cli"
if [ ! -x "$CLI_PATH" ]; then
    echo "Error: firezone CLI not found at $CLI_PATH" >&2
    echo "Run 'mise run //swift/apple:build' first." >&2
    exit 1
fi

echo "Testing: firezone tunnel connect (${TIMEOUT}s timeout)"
echo "CLI: $CLI_PATH"
echo "---"

# Run the CLI in the background, capture output to a temp file
outfile=$(mktemp)
"$CLI_PATH" > "$outfile" 2>&1 &
cli_pid=$!

# Wait for "Tunnel connected" in output, up to TIMEOUT seconds
elapsed=0
connected=false
while [ "$elapsed" -lt "$TIMEOUT" ]; do
    if grep -q "Tunnel connected" "$outfile" 2>/dev/null; then
        connected=true
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if $connected; then
    echo "PASS: tunnel connected within ${elapsed}s"
    # Gracefully shut down
    kill -TERM "$cli_pid" 2>/dev/null || true
    wait "$cli_pid" 2>/dev/null || true
else
    echo "FAIL: tunnel did not connect within ${TIMEOUT}s"
    kill -TERM "$cli_pid" 2>/dev/null || true
    wait "$cli_pid" 2>/dev/null || true
    echo "  Output:"
    cat "$outfile"
    rm -f "$outfile"
    exit 1
fi

rm -f "$outfile"
