#!/usr/bin/env bash
#MISE description="Photograph the macOS screens into swift/apple/screenshots/macos"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
# A fixed path rather than a fresh `mktemp -d`, so repeated runs keep one
# bundle instead of accumulating them. `xcodebuild` refuses to write over an
# existing bundle, so it is cleared before the run rather than after, which
# leaves the last one to inspect when the tests fail.
RESULT_BUNDLE="${TMPDIR:-/tmp}/FirezoneUITests.xcresult"

cd "${APPLE_DIR}"

rm -rf "${RESULT_BUNDLE}"

echo "Photographing the macOS screens..."
xcodebuild test \
    -project Firezone.xcodeproj \
    -scheme FirezoneUITests \
    -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    -resultBundlePath "${RESULT_BUNDLE}"

"${SCRIPT_DIR}/export-screenshots.sh" "${RESULT_BUNDLE}" "${APPLE_DIR}/screenshots/macos"
