#!/usr/bin/env bash
#MISE description="Build debug APK, boot emulator if needed, install and launch the app"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

PACKAGE="dev.firezone.android"
AVD_NAME="${AVD_NAME:-firezone}"
DEVICE_PROFILE="${DEVICE_PROFILE:-pixel_7}"

# Pick a system image based on host arch.
# x86_64 hosts (Linux, Intel Mac) use the x86_64 image; arm64 hosts (Apple Silicon)
# use arm64-v8a. Running an x86_64 image on Apple Silicon works only via slow translation.
case "$(uname -m)" in
x86_64 | amd64)
    HOST_ABI="x86_64"
    ;;
arm64 | aarch64)
    HOST_ABI="arm64-v8a"
    ;;
*)
    echo "Unsupported host arch: $(uname -m). Set SYSTEM_IMAGE manually." >&2
    exit 1
    ;;
esac
SYSTEM_IMAGE="${SYSTEM_IMAGE:-system-images;android-36;google_apis;${HOST_ABI}}"

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
export ANDROID_HOME
# avdmanager (cmdline-tools 7+) defaults to $XDG_CONFIG_HOME/.android, emulator still looks at $HOME/.android.
# Pin both to the same location.
export ANDROID_USER_HOME="${ANDROID_USER_HOME:-$HOME/.android}"
export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"

emulator_online() {
    adb devices | awk 'NR>1 && /^emulator-/ && $2=="device" {found=1} END {exit !found}'
}

ensure_emulator_pkg() {
    if [ -x "$ANDROID_HOME/emulator/emulator" ]; then
        return
    fi
    echo "==> Installing emulator package..."
    sdkmanager --sdk_root="$ANDROID_HOME" "emulator" >/dev/null
}

ensure_system_image() {
    local image_dir
    image_dir="$ANDROID_HOME/${SYSTEM_IMAGE//;//}"
    if [ -d "$image_dir" ]; then
        return
    fi
    echo "==> Installing system image: ${SYSTEM_IMAGE}..."
    yes 2>/dev/null | sdkmanager --sdk_root="$ANDROID_HOME" --licenses >/dev/null || true
    sdkmanager --sdk_root="$ANDROID_HOME" "$SYSTEM_IMAGE" >/dev/null
}

ensure_avd() {
    if avdmanager list avd 2>/dev/null | grep -qE "^\s*Name:\s+${AVD_NAME}\s*$"; then
        return
    fi
    echo "==> Creating AVD '${AVD_NAME}' (device=${DEVICE_PROFILE})..."
    echo no | avdmanager create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" -d "$DEVICE_PROFILE" >/dev/null
}

start_emulator() {
    if emulator_online; then
        echo "==> Emulator already online."
        return
    fi
    ensure_emulator_pkg
    ensure_system_image
    ensure_avd

    echo "==> Booting emulator '${AVD_NAME}'..."
    nohup emulator -avd "$AVD_NAME" -no-snapshot-save >/tmp/firezone-emulator.log 2>&1 &
    disown

    echo "==> Waiting for device..."
    adb wait-for-device

    echo "==> Waiting for boot to finish (up to 5 min; first run can be slow)..."
    for _ in $(seq 1 150); do
        if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
            return
        fi
        sleep 2
    done
    echo "Emulator did not finish booting within 5 min. See /tmp/firezone-emulator.log." >&2
    exit 1
}

start_emulator

echo "==> Installing debug APK (${HOST_ABI} only)..."
# Kill any running instance so the next launch is a clean cold start (and so
# Android doesn't keep the old process alive across install).
echo "==> Force-stopping any running instance of ${PACKAGE}..."
adb shell am force-stop "$PACKAGE"

# Build only the ABI the emulator uses; saves ~4x build time vs the default all-ABI build.
./gradlew installDebug "-Pandroid.injected.build.abi=$HOST_ABI"

# LAUNCH_COMPONENT lets callers (e.g. the sample-UI task) start a specific activity instead of the
# default launcher entry.
if [ -n "${LAUNCH_COMPONENT:-}" ]; then
    echo "==> Launching ${LAUNCH_COMPONENT}..."
    adb shell am start -n "$LAUNCH_COMPONENT" >/dev/null
else
    echo "==> Launching ${PACKAGE}..."
    adb shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null
fi

echo "==> Done. Emulator log: /tmp/firezone-emulator.log"
