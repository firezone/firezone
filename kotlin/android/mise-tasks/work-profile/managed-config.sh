#!/usr/bin/env bash
#MISE description="Point the app's managed configuration at the staged certificate alias"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Keep in sync with certificate.sh; both default to the same alias.
CERT_ALIAS="${CERT_ALIAS:-firezone-client}"
# X509_CERTIFICATE_ALIAS_RESTRICTION in `core/data/Repository.kt`.
RESTRICTION_KEY="x509CertificateAlias"
PACKAGE="dev.firezone.android"
DPC_PACKAGE="${DPC_PACKAGE:-com.afwsamples.testdpc}"

require_sdk_tool adb

user_id="$(require_work_profile_user)" || exit 1

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

adb_root || true

for _ in $(seq 1 150); do
    # Readable only because the AOSP images are userdebug; this is a convenience check, so a
    # device that refuses `adb root` just times out here without the setup being wrong.
    if adb shell cat "$restrictions_file" 2>/dev/null | grep -q "$RESTRICTION_KEY"; then
        echo "==> Applied:"
        adb shell cat "$restrictions_file" | sed 's/^/    /'
        echo
        echo "==> Restart the app to hit the certificate screen ('adb root' first if these are refused):"
        echo "    adb shell am force-stop --user ${user_id} ${PACKAGE}"
        echo "    adb shell am start --user ${user_id} -n ${PACKAGE}/.core.presentation.MainActivity"
        exit 0
    fi
    sleep 2
done

echo "==> Could not read ${restrictions_file}." >&2
echo "    Either the restriction is not set yet, or this device does not allow 'adb root'." >&2
echo "    Restart the app and see whether the certificate screen appears." >&2
