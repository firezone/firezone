#!/usr/bin/env bash
#MISE description="Give up ownership of the attached device and remove the test DPC"
set -Eeuo pipefail
# Any failure `set -e` would swallow names itself, so no death is ever silent.
trap 'echo "error: ${BASH_SOURCE[0]}:${LINENO}: command failed with exit $?: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_adb

user_id="$(managed_user)" || exit

if [ -z "$user_id" ]; then
    echo "==> ${DPC_PACKAGE} owns nothing on this device."
    exit 0
fi

# A work profile takes its owner, the app inside it and its KeyChain with it, which is the whole
# difference: the device's own user keeps everything that was ever installed into it.
if [ "$user_id" != "0" ]; then
    echo "==> Removing work profile ${user_id}..."
    adb shell pm remove-user "$user_id"
    adb shell dpm list-owners
    exit 0
fi

echo "==> Clearing the app's managed configuration..."
provision -a dev.firezone.dpc.SET_RESTRICTIONS --es package "$APP_PACKAGE" || true

# The package manager refuses to uninstall an app that owns the device, so ownership goes first.
echo "==> Giving up ownership..."
adb shell dpm remove-active-admin "$DPC_ADMIN" || {
    echo >&2
    echo "error: the device refused to release the admin. Wipe the emulator instead:" >&2
    echo "           emulator -avd <name> -wipe-data" >&2
    exit 1
}

echo "==> Uninstalling ${DPC_PACKAGE}..."
adb uninstall "$DPC_PACKAGE" || true

adb shell dpm list-owners

echo
echo "Certificates already in the KeyChain stay there; wipe the emulator to be rid of them."
