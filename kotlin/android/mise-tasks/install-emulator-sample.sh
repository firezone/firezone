#!/usr/bin/env bash
#MISE description="Build debug APK, boot emulator if needed, then launch the mock-data SampleSessionActivity (debug-only sample UI)"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Reuse the emulator bootstrap + install from install-emulator, but launch the debug-only sample
# activity instead of the real launcher entry.
exec env \
    LAUNCH_COMPONENT="dev.firezone.android/dev.firezone.android.features.session.ui.compose.SampleSessionActivity" \
    "${SCRIPT_DIR}/install-emulator.sh"
