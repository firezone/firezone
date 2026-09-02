#!/usr/bin/env bash
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

echo "Stopping any running Firezone instances..."
osascript -e 'tell application "Firezone" to quit' 2>/dev/null || true
pkill -x Firezone 2>/dev/null || true

# Both variants name the tunnel `dev.firezone.firezone.network-extension`, so an
# already activated system extension would shadow the App Store build's app
# extension. Clear it whichever variant is going in.
echo "Stopping and removing Firezone network extension..."
sudo pkill -f "Firezone.NetworkExtension" 2>/dev/null || true
# systemextensionsctl may fail if extension not installed - log but continue
sudo systemextensionsctl uninstall 47R2M6779T dev.firezone.firezone.network-extension 2>&1 || echo "Note: network-extension not installed or already removed"
sudo systemextensionsctl uninstall 47R2M6779T dev.firezone.firezone.network-extension-systemextension 2>&1 || echo "Note: network-extension-systemextension not installed or already removed"

sleep 2

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
if [ ! -d "$PRODUCTS_DIR/Firezone.app" ]; then
    echo "Error: Firezone.app not found at $PRODUCTS_DIR"
    echo "Run 'mise run build' first"
    exit 1
fi

echo "Copying app from $PRODUCTS_DIR to /Applications..."
sudo cp -R "$PRODUCTS_DIR/Firezone.app" /Applications/

echo "Launching Firezone..."
open /Applications/Firezone.app
