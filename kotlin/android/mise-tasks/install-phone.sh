#!/usr/bin/env bash
#MISE description="Build debug APK and install on connected Android device (matches device ABI)"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
export ANDROID_HOME
export PATH="$ANDROID_HOME/platform-tools:$PATH"

# Require exactly one device, unless ANDROID_SERIAL is set (then adb targets that one).
if [ -z "${ANDROID_SERIAL:-}" ]; then
    device_count=$(adb devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')
    case "$device_count" in
    0)
        echo "No Android device detected. Plug one in or run 'mise run install-emulator'." >&2
        exit 1
        ;;
    1) ;;
    *)
        echo "Multiple devices detected. Set ANDROID_SERIAL to pick one:" >&2
        adb devices >&2
        exit 1
        ;;
    esac
fi

DEVICE_ABI="$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"

echo "==> Installing debug APK (device ABI: ${DEVICE_ABI})..."
# Kill any running instance so the next launch is a clean cold start (and so
# Android doesn't keep the old process alive across install).
echo "==> Force-stopping any running instance of dev.firezone.android..."
adb shell am force-stop dev.firezone.android

gradle_args=("-Pandroid.injected.build.abi=$DEVICE_ABI")

install_log="$(mktemp "${TMPDIR:-/tmp}/install-phone.XXXXXX")"
trap 'rm -f "$install_log"' EXIT

if ./gradlew installDebug "${gradle_args[@]}" 2>&1 | tee "$install_log"; then
    exit 0
fi

if ! grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE" "$install_log"; then
    exit 1
fi

echo >&2
echo "==> Signature mismatch detected." >&2
echo "    A version of dev.firezone.android signed with a different key" >&2
echo "    (likely the Play Store release) is already installed." >&2

if [ "${REINSTALL:-0}" = "1" ]; then
    echo "==> REINSTALL=1; uninstalling without prompting." >&2
elif [ -t 0 ]; then
    read -r -p "Uninstall existing app and reinstall debug build? [y/N] " reply
    case "$reply" in
    [yY] | [yY][eE][sS]) ;;
    *)
        echo "Aborted." >&2
        exit 1
        ;;
    esac
else
    echo "    Re-run with REINSTALL=1 to uninstall and reinstall:" >&2
    echo "        REINSTALL=1 mise run install-phone" >&2
    exit 1
fi

echo "==> Uninstalling dev.firezone.android..."
adb uninstall dev.firezone.android
echo "==> Retrying install..."
./gradlew installDebug "${gradle_args[@]}"
