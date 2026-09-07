#!/usr/bin/env bash
#MISE description="Build the macOS app and its screenshot suite, to be run by screenshots-macos"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/FirezoneUITests-macos}"

cd "${APPLE_DIR}"

# Ad-hoc signing with the entitlements dropped: the mocked app touches none of
# the facilities they gate, and CI has no signing certificate.
xcodebuild build-for-testing \
    -project Firezone.xcodeproj \
    -scheme FirezoneUITests \
    -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER= \
    CODE_SIGN_ENTITLEMENTS= \
    ENABLE_APP_SANDBOX=NO \
    ENABLE_HARDENED_RUNTIME=NO \
    ONLY_ACTIVE_ARCH=YES
