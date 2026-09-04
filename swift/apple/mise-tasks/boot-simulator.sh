#!/usr/bin/env bash
#MISE description="Boot the gallery's pinned iOS simulator with a settled appearance"
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

xcrun simctl bootstatus "${udid}" -b

# Sheet toolbars draw over a material that does not rasterise identically twice.
xcrun simctl spawn "${udid}" defaults write \
  com.apple.Accessibility ReduceTransparencyEnabled -bool true

# A control mid-animation rasterises differently from one that has settled, and
# both hold still long enough to be photographed.
xcrun simctl spawn "${udid}" defaults write \
  com.apple.Accessibility ReduceMotionEnabled -bool true

# A bar button is drawn on a material of its own that reduced transparency does
# not reach; increased contrast replaces it with a solid fill.
xcrun simctl spawn "${udid}" defaults write \
  com.apple.Accessibility DarkerSystemColorsEnabled -bool true

echo "${udid}"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "SIMULATOR_UDID=${udid}" >>"${GITHUB_ENV}"
fi
