#!/usr/bin/env bash
#MISE description="Give up ownership of the attached device and remove the test DPC"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_adb

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
