#!/usr/bin/env bash
#MISE description="Print the UDID of the gallery's pinned iOS simulator"
set -euo pipefail

# Pinned rather than resolved as "latest": a newer runtime redraws the gallery.
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17}"
SIMULATOR_RUNTIME="${SIMULATOR_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-2}"

udid=$(xcrun simctl list devices available -j | jq -r \
    --arg name "${SIMULATOR_NAME}" --arg runtime "${SIMULATOR_RUNTIME}" \
    '.devices[$runtime] // [] | map(select(.name == $name)) | first | .udid // empty')

if [ -z "${udid}" ]; then
    echo "No ${SIMULATOR_NAME} on ${SIMULATOR_RUNTIME}; available devices:" >&2
    xcrun simctl list devices available >&2
    exit 1
fi

echo "${udid}"
