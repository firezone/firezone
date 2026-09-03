#!/usr/bin/env bash
#MISE description="Photograph the macOS screens into swift/apple/screenshots/macos/<release>"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
# A fixed path, cleared before the run rather than after: `xcodebuild` refuses to
# write over an existing bundle, and the last one stays around to inspect.
RESULT_BUNDLE="${RESULT_BUNDLE_DIR:-${TMPDIR:-/tmp}}/FirezoneUITests-macos.xcresult"

extra_args=()
if [ -n "${DERIVED_DATA_PATH:-}" ]; then
  extra_args+=(-derivedDataPath "${DERIVED_DATA_PATH}")
fi

cd "${APPLE_DIR}"

rm -rf "${RESULT_BUNDLE}"

# Ad-hoc signing with the entitlements dropped: the mocked app touches none of
# the facilities they gate, and CI has no signing certificate.
echo "Photographing the macOS screens..."
xcodebuild test \
    -project Firezone.xcodeproj \
    -scheme FirezoneUITests \
    -configuration Debug \
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

# SwiftUI lays a window out with the release it runs on, so the gallery keeps a
# directory per release.
"${SCRIPT_DIR}/export-screenshots.sh" "${RESULT_BUNDLE}" \
  "${APPLE_DIR}/screenshots/macos/$(sw_vers -productVersion | cut -d . -f 1)"
