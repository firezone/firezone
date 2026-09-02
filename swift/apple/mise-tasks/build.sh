#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
RUST_DIR="${SCRIPT_DIR}/../../../rust"
RUST_TARGET_DIR="${RUST_DIR}/target"
ARCH="$(uname -m)"
GIT_SHA="$(git rev-parse HEAD 2>/dev/null || echo "unknown")"

PLATFORM="${PLATFORM:-macOS}"
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

if [ ! -f buildServer.json ]; then
    echo "buildServer.json not found, generating LSP configuration..."
    mise run lsp
fi

# Ensure dynamic_build_number.xcconfig exists before Xcode parses the project
# This must exist BEFORE xcodebuild runs because Xcode parses xcconfig files
# at project load time, not during build phases
if [ ! -f Firezone/xcconfig/dynamic_build_number.xcconfig ]; then
    echo "Creating dynamic_build_number.xcconfig..."
    echo "CURRENT_PROJECT_VERSION = $(date +%s)" > Firezone/xcconfig/dynamic_build_number.xcconfig
fi

echo "Building Xcode project for ${PLATFORM}, ${ARCH} (${VARIANT})"
echo "Git SHA: ${GIT_SHA}"

# PRETTY=1 force on, PRETTY=0 force off, unset = auto-detect xcbeautify
if [ "${PRETTY:-}" = "0" ]; then
    USE_PRETTY=false
elif [ "${PRETTY:-}" = "1" ]; then
    if ! command -v xcbeautify &>/dev/null; then
        echo "Warning: PRETTY=1 but xcbeautify not found, install with: brew install xcbeautify" >&2
        USE_PRETTY=false
    else
        USE_PRETTY=true
    fi
else
    if command -v xcbeautify &>/dev/null; then
        USE_PRETTY=true
    else
        USE_PRETTY=false
    fi
fi

xcodebuild_args=(
    build
    -project Firezone.xcodeproj
    # Dev builds sign automatically; xcodebuild won't fetch or create a profile without this.
    # Release builds pass explicit profile ids instead, so they never reach for it.
    -allowProvisioningUpdates
    -scheme "${SCHEME}"
    -configuration "${CONFIGURATION}"
    -sdk macosx
    -destination "platform=${PLATFORM},arch=${ARCH}"
    RUST_TARGET_DIR="${RUST_TARGET_DIR}"
    GIT_SHA="${GIT_SHA}"
    ONLY_ACTIVE_ARCH=YES
)

if [ "$USE_PRETTY" = true ]; then
    echo "(using xcbeautify)"
    xcodebuild "${xcodebuild_args[@]}" 2>&1 | xcbeautify
else
    xcodebuild "${xcodebuild_args[@]}"
fi
