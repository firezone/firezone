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

# Map the device ABI to the cargo build tasks we can skip. The Gradle task names
# come from the targets list in app/build.gradle.kts.
case "$DEVICE_ABI" in
arm64-v8a)
    SKIP_CARGO_TASKS=(cargoBuildArm cargoBuildX86 cargoBuildX86_64)
    ;;
armeabi-v7a)
    SKIP_CARGO_TASKS=(cargoBuildArm64 cargoBuildX86 cargoBuildX86_64)
    ;;
x86_64)
    SKIP_CARGO_TASKS=(cargoBuildArm cargoBuildArm64 cargoBuildX86)
    ;;
x86)
    SKIP_CARGO_TASKS=(cargoBuildArm cargoBuildArm64 cargoBuildX86_64)
    ;;
*)
    echo "==> Unknown device ABI '${DEVICE_ABI}', falling back to all-ABI build."
    SKIP_CARGO_TASKS=()
    ;;
esac

echo "==> Installing debug APK (device ABI: ${DEVICE_ABI})..."
gradle_skip_args=()
for task in "${SKIP_CARGO_TASKS[@]}"; do
    gradle_skip_args+=(-x "$task")
done
./gradlew installDebug "${gradle_skip_args[@]}"
