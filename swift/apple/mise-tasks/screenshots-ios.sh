#!/usr/bin/env bash
#MISE description="Photograph the iOS screens into swift/apple/screenshots/ios"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
RESULT_DIR="${RESULT_BUNDLE_DIR:-${TMPDIR:-/tmp}}"

UDID="${SIMULATOR_UDID:-$("${SCRIPT_DIR}/simulator-udid.sh")}"

extra_args=()
if [ -n "${DERIVED_DATA_PATH:-}" ]; then
  extra_args+=(-derivedDataPath "${DERIVED_DATA_PATH}")
fi

cd "${APPLE_DIR}"

# Only the test runs need the simulator, so it boots alongside the build rather
# than before it: settling the device down takes three minutes of its own.
boot_log="$(mktemp)"
trap 'rm -f "${boot_log}"' EXIT
"${SCRIPT_DIR}/boot-simulator.sh" "${UDID}" >"${boot_log}" 2>&1 &
boot=$!

# The simulator asks for no signing, and the entitlements need a profile.
xcodebuild build-for-testing \
    -project Firezone.xcodeproj \
    -scheme FirezoneUITests \
    -configuration Debug \
    -destination "id=${UDID}" \
    "${extra_args[@]+"${extra_args[@]}"}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS= \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER= \
    ONLY_ACTIVE_ARCH=YES

boot_status=0
wait "${boot}" || boot_status=$?
cat "${boot_log}"
[ "${boot_status}" -eq 0 ] || exit "${boot_status}"

# An appearance belongs to the device rather than to a launch, so the suite runs
# once per appearance with `simctl ui` in between.
for appearance in light dark; do
  RESULT_BUNDLE="${RESULT_DIR}/FirezoneUITests-ios-${appearance}.xcresult"
  rm -rf "${RESULT_BUNDLE}"

  xcrun simctl ui "${UDID}" appearance "${appearance}"

  echo "Photographing the iOS screens in ${appearance}..."
  # xcodebuild forwards TEST_RUNNER_-prefixed variables with the prefix stripped.
  TEST_RUNNER_SCREENSHOT_APPEARANCE="${appearance}" \
    xcodebuild test-without-building \
      -project Firezone.xcodeproj \
      -scheme FirezoneUITests \
      -configuration Debug \
      -destination "id=${UDID}" \
      "${extra_args[@]+"${extra_args[@]}"}" \
      -resultBundlePath "${RESULT_BUNDLE}"

  "${SCRIPT_DIR}/export-screenshots.sh" "${RESULT_BUNDLE}" "${APPLE_DIR}/screenshots/ios"
done
