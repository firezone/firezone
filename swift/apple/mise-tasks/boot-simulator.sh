#!/usr/bin/env bash
#MISE description="Boot the gallery's pinned iOS simulator with a fixed status bar"
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

# The captures include the status bar, whose clock and battery move on every run.
# An iPad shows the date beside the clock, and simctl pins it only when given a
# full ISO 8601 timestamp, read in the host's zone like the simulator's clock.
pinned_time="$(date -j -f '%Y-%m-%d %H:%M' '2007-01-09 09:41' '+%Y-%m-%dT%H:%M:%S%z' |
  sed -E 's/([0-9]{2})$/:\1/')"
xcrun simctl status_bar "${udid}" override \
  --time "${pinned_time}" \
  --dataNetwork wifi \
  --wifiMode active \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4 \
  --batteryState charged \
  --batteryLevel 100

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
