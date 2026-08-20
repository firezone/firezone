#!/usr/bin/env bash
#MISE description="Create a managed work profile on the running emulator and give it a profile owner"
set -euo pipefail

# Simulating a personally-owned device with a work profile needs a Device Policy Controller: only a
# profile owner can install a key pair into the profile's KeyChain and push managed configuration to
# an app, and neither operation is reachable from `adb`. Google's reference DPC is TestDPC:
#
#     https://github.com/googlesamples/android-testdpc
#
# The emulator runs an AOSP image on purpose (see boot.sh), so it has no Play Store to install
# TestDPC from. Point TESTDPC_APK at an APK you built yourself:
#
#     git clone https://github.com/googlesamples/android-testdpc
#     cd android-testdpc && ./gradlew assembleDebug
#     export TESTDPC_APK="$PWD/app/build/outputs/apk/debug/TestDPC-debug.apk"
#
# 'work-profile:build-dpc' does that for you and leaves the APK where this task looks by default.
#
# Any other DPC works too: override DPC_PACKAGE and DPC_RECEIVER to match it.
DPC_PACKAGE="${DPC_PACKAGE:-com.afwsamples.testdpc}"
DPC_RECEIVER="${DPC_RECEIVER:-com.afwsamples.testdpc.DeviceAdminReceiver}"
PROFILE_NAME="${PROFILE_NAME:-Work}"

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
export ANDROID_HOME
export PATH="$ANDROID_HOME/platform-tools:$PATH"

if ! command -v adb >/dev/null 2>&1; then
    echo "adb not found in PATH. Run 'mise run setup' first." >&2
    exit 1
fi

TESTDPC_DIR="${TESTDPC_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/firezone/android-testdpc}"

if [ -z "${TESTDPC_APK:-}" ]; then
    TESTDPC_APK="$(find "$TESTDPC_DIR/app/build/outputs/apk/debug" -name '*.apk' -type f -print0 2>/dev/null |
        xargs -0 ls -t 2>/dev/null |
        head -1)"
fi

if [ -z "${TESTDPC_APK:-}" ]; then
    echo "No DPC to install. Build one:" >&2
    echo "    mise run //kotlin/android:work-profile:build-dpc" >&2
    echo "Or point TESTDPC_APK at an APK you built yourself." >&2
    exit 1
fi

if [ ! -f "$TESTDPC_APK" ]; then
    echo "TESTDPC_APK does not point at a file: ${TESTDPC_APK}" >&2
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

user_id="$(work_profile_user || true)"

if [ -n "$user_id" ]; then
    echo "==> Reusing existing work profile (user ${user_id})."
else
    echo "==> Creating managed profile '${PROFILE_NAME}'..."
    created="$(adb shell pm create-user --profileOf 0 --managed "$PROFILE_NAME" | tr -d '\r')"
    echo "    ${created}"
    user_id="$(echo "$created" | sed -n 's/.*created user id \([0-9][0-9]*\).*/\1/p')"

    if [ -z "$user_id" ]; then
        echo "Could not read the new user id out of: ${created}" >&2
        exit 1
    fi
fi

echo "==> Starting user ${user_id}..."
adb shell am start-user -w "$user_id" >/dev/null

echo "==> Installing the DPC into user ${user_id}..."
adb install -r -g --user "$user_id" "$TESTDPC_APK"

echo "==> Setting ${DPC_PACKAGE} as profile owner of user ${user_id}..."
# This is the step the account-free AOSP image buys us: `set-profile-owner` refuses a user that
# carries an account. It also refuses one that already has an owner, which is where a re-run of
# this task lands, so the failure is reported rather than fatal.
if ! adb shell dpm set-profile-owner --user "$user_id" "${DPC_PACKAGE}/${DPC_RECEIVER}"; then
    echo "    Could not set the profile owner. Harmless if this profile already has one." >&2
fi

echo "==> Owners now known to the device:"
adb shell dpm list-owners || true

echo
echo "==> Work profile ready as user ${user_id}."
echo "    Next: mise run //kotlin/android:work-profile:install-app"
