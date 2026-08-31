#!/usr/bin/env bash
#MISE description="Make the test Device Policy Controller the owner of the attached device"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

cd "${SCRIPT_DIR}/../.."

require_adb

if adb shell dpm list-owners | grep -q "$DPC_PACKAGE"; then
    echo "==> ${DPC_PACKAGE} already owns this device."
    exit 0
fi

echo "==> Building the DPC..."
./gradlew --quiet :dpc:assembleDebug

apk="$(find dpc/build -type f -name '*.apk' -exec ls -t {} + | head -1)"

if [ -z "$apk" ]; then
    echo "error: the build produced no APK under dpc/build" >&2
    exit 1
fi

echo "==> Installing ${apk}..."
adb install -r "$apk"

# A device owner can only be set while the device carries no accounts and nobody owns it yet, which
# is why this wants a freshly wiped emulator rather than the one you sign into.
echo "==> Making it the device owner..."
if ! adb shell dpm set-device-owner "$DPC_ADMIN"; then
    echo >&2
    echo "error: the device refused a device owner." >&2
    echo "       It has to carry no accounts and no other owner. Wipe the emulator and retry:" >&2
    echo "           emulator -avd <name> -wipe-data" >&2
    exit 1
fi

adb shell dpm list-owners
