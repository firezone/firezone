#!/usr/bin/env bash
#MISE description="Photograph the macOS screens into swift/apple/screenshots/macos/<release>"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/FirezoneUITests-macos}"
# A fixed path, cleared before the run rather than after: `xcodebuild` refuses to
# write over an existing bundle, and the last one stays around to inspect.
RESULT_BUNDLE="${RESULT_BUNDLE_DIR:-${TMPDIR:-/tmp}}/FirezoneUITests-macos.xcresult"

# The products of build-macos-ui-tests, which the test run finds through the
# xctestrun beside them.
XCTESTRUN="$(find "${DERIVED_DATA_PATH}/Build/Products" -maxdepth 1 -name '*.xctestrun' 2>/dev/null | head -n 1)"
if [ -z "${XCTESTRUN}" ]; then
  echo "No test products in ${DERIVED_DATA_PATH}; run the build-macos-ui-tests task first" >&2
  exit 1
fi

cd "${APPLE_DIR}"

rm -rf "${RESULT_BUNDLE}"

echo "Photographing the macOS screens..."
xcodebuild test-without-building \
    -xctestrun "${XCTESTRUN}" \
    -destination "platform=macOS,arch=$(uname -m)" \
    -resultBundlePath "${RESULT_BUNDLE}"

# SwiftUI lays a window out with the release it runs on, so the gallery keeps a
# directory per release.
"${SCRIPT_DIR}/export-screenshots.sh" "${RESULT_BUNDLE}" \
  "${APPLE_DIR}/screenshots/macos/$(sw_vers -productVersion | cut -d . -f 1)"
