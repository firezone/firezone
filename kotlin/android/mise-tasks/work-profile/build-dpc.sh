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

# TestDPC patches the setupdesign library it pulls in, with `ed`, while fetching its dependencies.
if ! command -v ed >/dev/null 2>&1; then
    echo "TestDPC's build needs 'ed'. Install it with your package manager (e.g. 'sudo dnf install ed')." >&2
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

# Bazel finds the SDK through ANDROID_HOME but not the platform TestDPC compiles against, which it
# names in its own WORKSPACE so that reading it from there keeps up with upstream.
api_level="$(sed -n 's/.*api_level *= *\([0-9][0-9]*\).*/\1/p' "$TESTDPC_DIR/WORKSPACE" | head -1 || true)"

if [ -n "$api_level" ] && [ ! -d "$ANDROID_HOME/platforms/android-${api_level}" ]; then
    require_sdk_tool sdkmanager

    echo "==> Installing platform android-${api_level}..."
    yes 2>/dev/null | sdkmanager --sdk_root="$ANDROID_HOME" --licenses >/dev/null || true
    sdkmanager --sdk_root="$ANDROID_HOME" "platforms;android-${api_level}" >/dev/null
fi

echo "==> Building the APK..."
# `bazelisk` reads TestDPC's .bazelversion and fetches the Bazel release it asks for. The target name
# is upstream's own: `build.sh` in the checkout runs exactly this.
(cd "$TESTDPC_DIR" && bazelisk build testdpc)

apk="$(testdpc_apk)"

if [ ! -f "$apk" ]; then
    echo "The build produced no APK at ${apk}." >&2
    exit 1
fi

echo
echo "==> Built ${apk}"
echo "    'work-profile:create' picks this up on its own; export TESTDPC_APK to use a different one."
echo "    Next: mise run //kotlin/android:work-profile:boot"
