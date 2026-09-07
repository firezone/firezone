#!/usr/bin/env bash
#MISE description="Build the iOS app and its screenshot suite for the simulator, to be run by screenshots-ios"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/FirezoneUITests-ios}"

cd "${APPLE_DIR}"

# Built for the simulator in general rather than a particular one: the same
# products run on every simulator, so one build serves an iPhone and an iPad.
# The simulator asks for no signing, and the entitlements need a profile.
xcodebuild build-for-testing \
    -project Firezone.xcodeproj \
    -scheme FirezoneUITests \
    -configuration Debug \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS= \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER= \
    ONLY_ACTIVE_ARCH=YES
