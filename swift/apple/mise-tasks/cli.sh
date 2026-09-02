#!/usr/bin/env bash
# mise description="Run FirezoneCLI headless client"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
CONFIGURATION="${CONFIGURATION:-Debug}"

# macOS ships two variants: `standalone` carries the tunnel as a system extension it
# installs, `appstore` bundles it as an app extension. They are separate app targets.
VARIANT="${VARIANT:-standalone}"
case "${VARIANT}" in
standalone) SCHEME="FirezoneStandalone" ;;
appstore) SCHEME="Firezone" ;;
*)
    echo "Unknown VARIANT '${VARIANT}'; expected 'standalone' or 'appstore'" >&2
    exit 1
    ;;
esac

cd "${APPLE_DIR}"

echo "Finding build location..."
xcodebuild_output=$(xcodebuild -project Firezone.xcodeproj -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -showBuildSettings 2>&1) || {
    echo "Error: xcodebuild failed:"
    echo "$xcodebuild_output" >&2
    exit 1
}
PRODUCTS_DIR=$(echo "$xcodebuild_output" | grep ' BUILT_PRODUCTS_DIR = ' | sed 's/.*= //')
if [ -z "$PRODUCTS_DIR" ]; then
    echo "Error: Could not determine build products directory"
    exit 1
fi

CLI_PATH="$PRODUCTS_DIR/Firezone.app/Contents/MacOS/firezone-cli"
if [ ! -x "$CLI_PATH" ]; then
    echo "Error: firezone CLI not found at $CLI_PATH"
    exit 1
fi

echo "Binary: $CLI_PATH"
printf 'Running: firezone-cli'
printf ' %q' "$@"
printf '\n'
echo "---"
exec "$CLI_PATH" "$@"
