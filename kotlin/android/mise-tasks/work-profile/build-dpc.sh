#!/usr/bin/env bash
#MISE description="Build Google's TestDPC so the work profile has a Device Policy Controller"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

# The emulator runs an AOSP image so the work profile stays free of accounts (see boot.sh), which
# also means it has no Play Store to install TestDPC from. Building it from source is the only way
# to get a profile owner onto the device.
TESTDPC_REPO="${TESTDPC_REPO:-https://github.com/googlesamples/android-testdpc}"
TESTDPC_DIR="$(testdpc_dir)"

if [ ! -d "$ANDROID_HOME" ]; then
    echo "No Android SDK at ${ANDROID_HOME}. Run 'mise run //kotlin/android:setup-sdk' first." >&2
    exit 1
fi

if [ -d "$TESTDPC_DIR/.git" ]; then
    echo "==> Updating TestDPC in ${TESTDPC_DIR}..."
    git -C "$TESTDPC_DIR" pull --ff-only
else
    echo "==> Cloning TestDPC into ${TESTDPC_DIR}..."
    mkdir -p "$(dirname "$TESTDPC_DIR")"
    git clone --depth 1 "$TESTDPC_REPO" "$TESTDPC_DIR"
fi

echo "==> Building the debug APK..."
# TestDPC ships its own wrapper, and its AGP reads the SDK location from ANDROID_HOME.
(cd "$TESTDPC_DIR" && ./gradlew --no-daemon assembleDebug)

apk="$(newest_testdpc_apk)"

if [ -z "$apk" ]; then
    echo "The build produced no APK under ${TESTDPC_DIR}/app/build/outputs/apk/debug." >&2
    exit 1
fi

echo
echo "==> Built ${apk}"
echo "    'work-profile:create' picks this up on its own; export TESTDPC_APK to use a different one."
echo "    Next: mise run //kotlin/android:work-profile:boot"
