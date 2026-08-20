#!/usr/bin/env bash
#MISE description="Build the debug APK and install it into the work profile"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

cd "${SCRIPT_DIR}/../.."

PACKAGE="dev.firezone.android"

if ! HOST_ABI="$(host_abi)"; then
    echo "Unsupported host arch: $(uname -m)." >&2
    exit 1
fi

require_sdk_tool adb

user_id="$(require_work_profile_user)" || exit 1

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
