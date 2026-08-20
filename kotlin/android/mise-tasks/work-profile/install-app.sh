#!/usr/bin/env bash
#MISE description="Build the debug APK and install it into the work profile"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/../.."

PACKAGE="dev.firezone.android"

case "$(uname -m)" in
x86_64 | amd64) HOST_ABI="x86_64" ;;
arm64 | aarch64) HOST_ABI="arm64-v8a" ;;
*)
    echo "Unsupported host arch: $(uname -m)." >&2
    exit 1
    ;;
esac

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
export ANDROID_HOME
export PATH="$ANDROID_HOME/platform-tools:$PATH"

if ! command -v adb >/dev/null 2>&1; then
    echo "adb not found in PATH. Run 'mise run setup' first." >&2
    exit 1
fi

# FLAG_MANAGED_PROFILE is 0x20 in the hex flags `pm list users` prints per user.
work_profile_user() {
    adb shell pm list users 2>/dev/null |
        tr -d '\r' |
        sed -n 's/.*UserInfo{\([0-9][0-9]*\):[^:]*:\([0-9a-fA-F][0-9a-fA-F]*\)}.*/\1 \2/p' |
        while read -r id flags; do
            if [ $((0x$flags & 0x20)) -ne 0 ]; then
                echo "$id"
            fi
        done |
        head -1
}

user_id="${WORK_PROFILE_USER:-$(work_profile_user || true)}"

if [ -z "$user_id" ]; then
    echo "No work profile found. Is the emulator running?" >&2
    echo "Create one with 'mise run //kotlin/android:work-profile:create'." >&2
    exit 1
fi

# `installDebug` targets user 0, so the APK is built and then installed into the profile by hand.
echo "==> Building the debug APK (${HOST_ABI} only)..."
./gradlew assembleDebug "-Pandroid.injected.build.abi=$HOST_ABI"

apk="$(find app/build/outputs/apk/debug -name '*.apk' -print 2>/dev/null | head -1 || true)"

if [ -z "$apk" ]; then
    echo "No debug APK under app/build/outputs/apk/debug." >&2
    exit 1
fi

echo "==> Force-stopping any running instance of ${PACKAGE} in user ${user_id}..."
adb shell am force-stop --user "$user_id" "$PACKAGE"

echo "==> Installing ${apk} into user ${user_id}..."
adb install -r -g --user "$user_id" "$apk"

echo
echo "==> Installed. Next: mise run //kotlin/android:work-profile:certificate"
