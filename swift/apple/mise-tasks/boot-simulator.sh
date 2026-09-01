#!/usr/bin/env bash
#MISE description="Boot the gallery's pinned iOS simulator with a fixed status bar"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

udid="${1:-$("${SCRIPT_DIR}/simulator-udid.sh")}"

xcrun simctl bootstatus "${udid}" -b

# The captures include the status bar, whose clock and battery move on every run.
xcrun simctl status_bar "${udid}" override \
  --time "9:41" \
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

# A banner drawn over the app is photographed with it: the gallery once carried a
# "Ready for Apple Intelligence" notice across the navigation bar. Best effort,
# because the keys have moved between releases and a capture waits a banner out.
xcrun simctl spawn "${udid}" defaults write com.apple.springboard SBEnableDoNotDisturb -bool true \
  2>/dev/null || echo "::warning::Could not turn on Do Not Disturb via SpringBoard"
xcrun simctl spawn "${udid}" defaults write com.apple.donotdisturb.DoNotDisturbSettings \
  dndThroughUnlockEnabled -bool true \
  2>/dev/null || echo "::warning::Could not turn on Do Not Disturb via its settings"

echo "${udid}"
