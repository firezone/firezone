#!/usr/bin/env bash
#MISE description="Point the app's managed configuration at the staged certificate alias"
set -euo pipefail

# Keep in sync with certificate.sh; both default to the same alias.
CERT_ALIAS="${CERT_ALIAS:-firezone-client}"
# X509_CERTIFICATE_ALIAS_RESTRICTION in `core/data/Repository.kt`.
RESTRICTION_KEY="x509CertificateAlias"
PACKAGE="dev.firezone.android"
DPC_PACKAGE="${DPC_PACKAGE:-com.afwsamples.testdpc}"

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

restrictions_file="/data/system/users/${user_id}/res_${PACKAGE}.xml"

# `DevicePolicyManager.setApplicationRestrictions` is a profile-owner API with no adb equivalent,
# so this step belongs to the DPC's UI. What is left to script is telling you the exact key and
# then watching for the result to land.
echo "Set the managed configuration through ${DPC_PACKAGE} in the work profile:"
echo
echo "  1. Open TestDPC in the work profile."
echo "  2. Pick 'Manage app restrictions' and choose ${PACKAGE}."
echo "  3. Add a string entry:"
echo "         key:   ${RESTRICTION_KEY}"
echo "         value: ${CERT_ALIAS}"
echo "  4. Save. TestDPC applies it immediately."
echo
echo "==> Waiting up to 5 min for the restriction to appear (Ctrl-C to stop waiting)..."

adb root >/dev/null 2>&1 && adb wait-for-device || true

for _ in $(seq 1 150); do
    # Readable only because the AOSP images are userdebug; this is a convenience check, so a
    # device that refuses `adb root` just times out here without the setup being wrong.
    if adb shell cat "$restrictions_file" 2>/dev/null | grep -q "$RESTRICTION_KEY"; then
        echo "==> Applied:"
        adb shell cat "$restrictions_file" | sed 's/^/    /'
        echo
        echo "==> Restart the app to hit the certificate screen:"
        echo "    adb shell am force-stop --user ${user_id} ${PACKAGE}"
        echo "    adb shell am start --user ${user_id} -n ${PACKAGE}/.core.presentation.MainActivity"
        exit 0
    fi
    sleep 2
done

echo "==> Could not read ${restrictions_file}." >&2
echo "    Either the restriction is not set yet, or this device does not allow 'adb root'." >&2
echo "    Restart the app and see whether the certificate screen appears." >&2
