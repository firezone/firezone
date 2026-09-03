#!/usr/bin/env bash
#MISE description="Photograph the iOS screens on the booted simulator into swift/apple/screenshots/ios"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
RESULT_DIR="${RESULT_BUNDLE_DIR:-${TMPDIR:-/tmp}}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/FirezoneUITests-ios}"

UDID="${SIMULATOR_UDID:-$(xcrun simctl list devices booted -j \
  | jq -r '[.devices[][]] | first | .udid // empty')}"
if [ -z "${UDID}" ]; then
  echo "No booted simulator; run the boot-simulator task first" >&2
  exit 1
fi

# The products of build-screenshots-ios, which the test run finds through the
# xctestrun beside them.
XCTESTRUN="$(find "${DERIVED_DATA_PATH}/Build/Products" -maxdepth 1 -name '*.xctestrun' 2>/dev/null | head -n 1)"
if [ -z "${XCTESTRUN}" ]; then
  echo "No test products in ${DERIVED_DATA_PATH}; run the build-screenshots-ios task first" >&2
  exit 1
fi

cd "${APPLE_DIR}"

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
      -xctestrun "${XCTESTRUN}" \
      -destination "id=${UDID}" \
      -resultBundlePath "${RESULT_BUNDLE}"

  "${SCRIPT_DIR}/export-screenshots.sh" "${RESULT_BUNDLE}" "${APPLE_DIR}/screenshots/ios"
done
