#!/usr/bin/env bash
#MISE description="Photograph the macOS screens into swift/apple/screenshots/macos"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
# A fixed path rather than a fresh `mktemp -d`, so repeated runs keep one
# bundle instead of accumulating them. `xcodebuild` refuses to write over an
# existing bundle, so it is cleared before the run rather than after, which
# leaves the last one to inspect when the tests fail.
RESULT_BUNDLE="${RESULT_BUNDLE_DIR:-${TMPDIR:-/tmp}}/FirezoneUITests-macos.xcresult"

extra_args=()
if [ -n "${DERIVED_DATA_PATH:-}" ]; then
  extra_args+=(-derivedDataPath "${DERIVED_DATA_PATH}")
fi

cd "${APPLE_DIR}"

rm -rf "${RESULT_BUNDLE}"

# Ad-hoc signing with the entitlements dropped: the mocked app touches none of
# the facilities they gate, and CI has no signing certificate.
#
# `DebugUITest` is the Debug configuration with the `UITEST` condition on top:
# the app presents the window `--mock-window` names at launch and suppresses
# the rest (see `FirezoneApp.swift`).
echo "Photographing the macOS screens..."
xcodebuild test \
    -project Firezone.xcodeproj \
    -scheme FirezoneUITests \
    -configuration DebugUITest \
    -destination "platform=macOS,arch=$(uname -m)" \
    -resultBundlePath "${RESULT_BUNDLE}" \
    "${extra_args[@]+"${extra_args[@]}"}" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER= \
    CODE_SIGN_ENTITLEMENTS= \
    ENABLE_APP_SANDBOX=NO \
    ENABLE_HARDENED_RUNTIME=NO \
    ONLY_ACTIVE_ARCH=YES

"${SCRIPT_DIR}/export-screenshots.sh" "${RESULT_BUNDLE}" "${APPLE_DIR}/screenshots/macos"
