#!/usr/bin/env bash
#MISE description="Photograph the macOS screens into swift/apple/screenshots/macos"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
RESULT_BUNDLE="$(mktemp -d)/FirezoneUITests.xcresult"

cd "${APPLE_DIR}"

echo "Photographing the macOS screens..."
xcodebuild test \
    -project Firezone.xcodeproj \
    -scheme FirezoneUITests \
    -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    -resultBundlePath "${RESULT_BUNDLE}"

"${SCRIPT_DIR}/export-screenshots.sh" "${RESULT_BUNDLE}" "${APPLE_DIR}/screenshots/macos"
