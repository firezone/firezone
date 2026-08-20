#!/usr/bin/env bash
#MISE description="Build Google's TestDPC so the work profile has a Device Policy Controller"
set -euo pipefail

# The emulator runs an AOSP image so the work profile stays free of accounts (see boot.sh), which
# also means it has no Play Store to install TestDPC from. Building it from source is the only way
# to get a profile owner onto the device.
TESTDPC_REPO="${TESTDPC_REPO:-https://github.com/googlesamples/android-testdpc}"
TESTDPC_DIR="${TESTDPC_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/firezone/android-testdpc}"

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
export ANDROID_HOME

if [ ! -d "$ANDROID_HOME" ]; then
    echo "No Android SDK at ${ANDROID_HOME}. Run 'mise run //kotlin/android:work-profile:setup' first." >&2
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

# The artifact has been named TestDPC-debug.apk for years, but taking the newest APK under the
# debug output directory survives a rename upstream.
apk="$(find "$TESTDPC_DIR/app/build/outputs/apk/debug" -name '*.apk' -type f -print0 2>/dev/null |
    xargs -0 ls -t 2>/dev/null |
    head -1)"

if [ -z "$apk" ]; then
    echo "The build produced no APK under ${TESTDPC_DIR}/app/build/outputs/apk/debug." >&2
    exit 1
fi

echo
echo "==> Built ${apk}"
echo "    'work-profile:create' picks this up on its own; export TESTDPC_APK to use a different one."
echo "    Next: mise run //kotlin/android:work-profile:boot"
