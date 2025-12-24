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

echo "Building Xcode project for ${PLATFORM}, ${ARCH}"
echo "Git SHA: ${GIT_SHA}"

xcodebuild build \
    -project Firezone.xcodeproj \
    -scheme Firezone \
    -configuration "${CONFIGURATION}" \
    -sdk macosx \
    -destination "platform=${PLATFORM},arch=${ARCH}" \
    CONNLIB_TARGET_DIR="${RUST_TARGET_DIR}" \
    GIT_SHA="${GIT_SHA}" \
    ONLY_ACTIVE_ARCH=YES
