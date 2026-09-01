#!/usr/bin/env bash
#MISE description="Make the test Device Policy Controller the owner of the attached device or of a work profile"
#USAGE flag "--work-profile" help="Own a managed work profile rather than the device, the way a personally-owned device is managed"
set -Eeuo pipefail
# Any failure `set -e` would swallow names itself, so no death is ever silent.
trap 'echo "error: ${BASH_SOURCE[0]}:${LINENO}: command failed with exit $?: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_parsed_flags "$@"

cd "${SCRIPT_DIR}/../.."

require_adb

owned="$(managed_user)" || exit

if [ -n "$owned" ]; then
    echo "==> ${DPC_PACKAGE} already owns user ${owned}."
    exit 0
fi

# CI restores a prebuilt APK where a build would cost the emulator job a toolchain.
dpc_apk="$(find dpc/build -type f -name '*.apk' -exec ls -t {} + 2>/dev/null | head -1)" || true

if [ -z "$dpc_apk" ]; then
    echo "==> Building the DPC..."
    ./gradlew --quiet :dpc:assembleDebug

    dpc_apk="$(find dpc/build -type f -name '*.apk' -exec ls -t {} + 2>/dev/null | head -1)" || true
fi

if [ -z "$dpc_apk" ]; then
    echo "error: no APK under dpc/build" >&2
    exit 1
fi

if [ "${usage_work_profile:-}" != "true" ]; then
    echo "==> Installing ${dpc_apk}..."
    adb install -r "$dpc_apk"

    # A device owner can only be set while the device carries no accounts and nobody owns it yet,
    # which is why this wants a freshly wiped emulator rather than the one you sign into.
    echo "==> Making it the device owner..."
    if ! adb shell dpm set-device-owner "$DPC_ADMIN"; then
        echo >&2
        echo "error: the device refused a device owner." >&2
        echo "       It has to carry no accounts and no other owner. Wipe the emulator and retry:" >&2
        echo "           emulator -avd <name> -wipe-data" >&2
        exit 1
    fi

    adb shell dpm list-owners
    exit 0
fi

echo "==> Creating a managed profile..."
created="$(adb shell pm create-user --profileOf 0 --managed Work | tr -d '\r')"
echo "    ${created}"
user_id="$(echo "$created" | sed -n 's/.*id \([0-9][0-9]*\).*/\1/p')"

if [ -z "$user_id" ]; then
    echo "error: could not read a user id out of: ${created}" >&2
    echo "       A device that carries no managed_users feature cannot host a work profile." >&2
    exit 1
fi

echo "==> Starting user ${user_id}..."
adb shell am start-user -w "$user_id" >/dev/null

echo "==> Installing the DPC into user ${user_id}..."
adb install -r --user "$user_id" "$dpc_apk"

# `set-profile-owner` refuses a user that carries an account, which is why the emulator images
# these tasks expect are the ones without Play Services.
echo "==> Making it the profile owner..."
adb shell dpm set-profile-owner --user "$user_id" "$DPC_ADMIN"

# Nothing else can put the app inside the profile, and the states are about what the app sees.
app_apk="$(find_apk 'app-debug.apk')"

if [ -n "$app_apk" ]; then
    echo "==> Installing ${app_apk} into user ${user_id}..."
    adb install -r -g -t --user "$user_id" "$app_apk"
else
    echo
    echo "==> Build the app and put it in the profile before expecting it to see anything:"
    echo "    ./gradlew assembleDebug -Pandroid.injected.build.abi=x86_64"
    echo "    adb install -r -g -t --user ${user_id} <the APK it wrote>"
fi

adb shell dpm list-owners
