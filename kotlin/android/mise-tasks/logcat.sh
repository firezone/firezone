#!/usr/bin/env bash
#MISE description="Stream colored logcat from the connected Android device/emulator"
set -euo pipefail

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
export ANDROID_HOME
export PATH="$ANDROID_HOME/platform-tools:$PATH"

if ! command -v adb >/dev/null 2>&1; then
    echo "adb not found in PATH. Run 'mise run setup' first." >&2
    exit 1
fi

# Require exactly one device, unless ANDROID_SERIAL is set (then adb targets that one).
if [ -z "${ANDROID_SERIAL:-}" ]; then
    device_count=$(adb devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')
    case "$device_count" in
    0)
        echo "No Android device or emulator online. Run 'mise run install-emulator' or plug a device in." >&2
        exit 1
        ;;
    1) ;;
    *)
        echo "Multiple devices detected. Set ANDROID_SERIAL to pick one:" >&2
        adb devices >&2
        exit 1
        ;;
    esac
fi

echo "==> Streaming logcat (Ctrl-C to stop). Pass tag filters after '--', e.g.:" >&2
echo "    mise run logcat -- 'connlib:V *:S'" >&2

# -T 1 starts at the newest line so we don't dump the full ring buffer first.
# Anything after '--' on the mise command line lands in $@ and is forwarded to
# logcat as a tag filterspec (see logcat(1)).
exec adb logcat --format=color -T 1 "$@"
