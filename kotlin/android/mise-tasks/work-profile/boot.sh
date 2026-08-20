#!/usr/bin/env bash
#MISE description="Create and boot an AOSP emulator (no Google accounts) for work-profile testing"
set -euo pipefail

AVD_NAME="${AVD_NAME:-firezone-work-profile}"
DEVICE_PROFILE="${DEVICE_PROFILE:-pixel_7}"

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

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
export ANDROID_HOME
# avdmanager (cmdline-tools 7+) defaults to $XDG_CONFIG_HOME/.android, emulator still looks at $HOME/.android.
# Pin both to the same location.
export ANDROID_USER_HOME="${ANDROID_USER_HOME:-$HOME/.android}"
export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"

SYSTEM_IMAGE="${SYSTEM_IMAGE:-}"

newest_image() {
    sdkmanager --list 2>/dev/null |
        cut -d'|' -f1 |
        tr -d '[:space:]' |
        grep -E "^system-images;android-[0-9]+;$1;${HOST_ABI}\$" |
        sort -V |
        tail -1
}

# A profile owner can only be set on a user that carries no accounts, and the Play-flavoured images
# sign the emulator into an account during first boot. The AOSP images ship no Play services at all,
# so the work profile stays account-free and `dpm set-profile-owner` keeps working. They are also
# userdebug builds, which is what lets the later tasks use `adb root` to stage files into the
# profile's storage.
#
# Resolved on demand rather than up front, so an existing AVD boots without asking the network what
# is available.
resolve_system_image() {
    if [ -n "$SYSTEM_IMAGE" ]; then
        return
    fi

    # `default` is the plain AOSP image. `aosp_atd` is the slimmed-down automated-test variant of
    # the same thing; it boots faster but drops apps, so it is only the fallback for API levels that
    # no longer publish `default`.
    for variant in default aosp_atd; do
        # `grep` finding nothing is an answer, not a failure, so it must not trip `set -e`.
        SYSTEM_IMAGE="$(newest_image "$variant" || true)"
        if [ -n "$SYSTEM_IMAGE" ]; then
            return
        fi
    done

    echo "No AOSP system image found for ${HOST_ABI}." >&2
    echo "List what your SDK offers with 'sdkmanager --list | grep system-images' and set SYSTEM_IMAGE." >&2
    exit 1
}

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
    if avdmanager list avd 2>/dev/null | grep -qE "^\s*Name:\s+${AVD_NAME}\s*\$"; then
        return
    fi

    resolve_system_image
    ensure_system_image

    echo "==> Creating AVD '${AVD_NAME}' (device=${DEVICE_PROFILE}, image=${SYSTEM_IMAGE})..."
    echo no | avdmanager create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" -d "$DEVICE_PROFILE" >/dev/null
}

if emulator_online; then
    echo "==> Emulator already online."
else
    ensure_emulator_pkg
    ensure_avd

    echo "==> Booting emulator '${AVD_NAME}'..."
    nohup emulator -avd "$AVD_NAME" -no-snapshot-save >/tmp/firezone-work-profile-emulator.log 2>&1 &
    disown

    echo "==> Waiting for device..."
    adb wait-for-device

    echo "==> Waiting for boot to finish (up to 5 min; first run can be slow)..."
    booted=0
    for _ in $(seq 1 150); do
        if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
            booted=1
            break
        fi
        sleep 2
    done
    if [ "$booted" != "1" ]; then
        echo "Emulator did not finish booting within 5 min. See /tmp/firezone-work-profile-emulator.log." >&2
        exit 1
    fi
fi

echo "==> Booted. Next: mise run //kotlin/android:work-profile:create"
