#!/usr/bin/env bash
#MISE description="Create a managed work profile on the running emulator and give it a profile owner"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

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
#     cd android-testdpc && bazelisk build testdpc
#     export TESTDPC_APK="$PWD/bazel-bin/testdpc.apk"
#
# 'work-profile:build-dpc' does that for you and leaves the APK where this task looks by default.
#
# Any other DPC works too: override DPC_PACKAGE and DPC_RECEIVER to match it.
DPC_PACKAGE="${DPC_PACKAGE:-com.afwsamples.testdpc}"
DPC_RECEIVER="${DPC_RECEIVER:-com.afwsamples.testdpc.DeviceAdminReceiver}"
PROFILE_NAME="${PROFILE_NAME:-Work}"

require_sdk_tool adb

TESTDPC_APK="${TESTDPC_APK:-$(testdpc_apk)}"

if [ ! -f "$TESTDPC_APK" ]; then
    echo "No DPC to install at ${TESTDPC_APK}. Build one:" >&2
    echo "    mise run //kotlin/android:work-profile:build-dpc" >&2
    echo "Or point TESTDPC_APK at an APK you built yourself." >&2
    exit 1
fi

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
