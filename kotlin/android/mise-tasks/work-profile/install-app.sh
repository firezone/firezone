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

if ! adb_root; then
    echo "This device refuses 'adb root', so nothing can install into the work profile." >&2
    echo "Boot the emulator through 'mise run //kotlin/android:work-profile:boot', which picks a" >&2
    echo "userdebug AOSP image." >&2
    exit 1
fi

user_id="$(require_work_profile_user)" || exit 1

# `installDebug` targets user 0, so the APK is built and then installed into the profile by hand.
echo "==> Building the debug APK (${HOST_ABI} only)..."
./gradlew assembleDebug "-Pandroid.injected.build.abi=$HOST_ABI"

# `-Pandroid.injected.build.abi` is how Android Studio asks for a single-ABI deployable build, and
# AGP leaves that APK under `intermediates` instead of copying it to `outputs`. Searching both, newest
# first, is what stops a stale `outputs` APK from being installed over the one just built.
# `-exec ... +` runs nothing when nothing matches, where piping into `xargs ls -t` would list the
# working directory instead.
apk="$(find app/build/intermediates/apk app/build/outputs/apk -type f -name '*.apk' -exec ls -t {} + 2>/dev/null | head -1 || true)"

if [ -z "$apk" ]; then
    echo "The build produced no APK under app/build. What is there:" >&2
    find app/build/intermediates/apk app/build/outputs/apk 2>/dev/null | sed 's/^/    /' >&2 || true
    exit 1
fi

echo "==> Force-stopping any running instance of ${PACKAGE} in user ${user_id}..."
# The reinstall below terminates the app regardless, so this is worth a note rather than the task.
if ! adb shell am force-stop --user "$user_id" "$PACKAGE" 2>/dev/null; then
    echo "    Refused; the reinstall stops it anyway."
fi

echo "==> Installing ${apk} into user ${user_id}..."
# `-t` because the injected-ABI build is the one Android Studio deploys, and AGP marks it
# `android:testOnly`, which the package manager otherwise refuses to install.
adb install -r -g -t --user "$user_id" "$apk"

echo
echo "==> Installed. Next: mise run //kotlin/android:work-profile:certificate"
