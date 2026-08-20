#!/usr/bin/env bash
#MISE description="Create and boot an AOSP emulator (no Google accounts) for work-profile testing"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

AVD_NAME="${AVD_NAME:-firezone-work-profile}"
DEVICE_PROFILE="${DEVICE_PROFILE:-pixel_7}"

if ! HOST_ABI="$(host_abi)"; then
    echo "Unsupported host arch: $(uname -m). Set SYSTEM_IMAGE manually." >&2
    exit 1
fi

require_sdk_tool sdkmanager
require_sdk_tool avdmanager
require_sdk_tool adb

# avdmanager (cmdline-tools 7+) defaults to $XDG_CONFIG_HOME/.android, emulator still looks at $HOME/.android.
# Pin both to the same location.
export ANDROID_USER_HOME="${ANDROID_USER_HOME:-$HOME/.android}"

SYSTEM_IMAGE="${SYSTEM_IMAGE:-}"

# The package paths out of the table `sdkmanager --list` prints, one per line. `[:blank:]` rather
# than `[:space:]`, which includes the newlines and would collapse the listing onto a single line.
list_images() {
    # `grep` finding nothing is an answer, not a failure, so it must not trip `set -e`.
    echo "$1" |
        cut -d'|' -f1 |
        tr -d '[:blank:]' |
        grep -E "^system-images;$2;${HOST_ABI}\$" |
        sort -V || true
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

    local packages
    if ! packages="$(sdkmanager --list 2>&1)"; then
        echo "$packages" >&2
        echo "Could not list the packages of the SDK at ${ANDROID_HOME}." >&2
        exit 1
    fi

    # `default` is the plain AOSP image. `aosp_atd` is the slimmed-down automated-test variant of
    # the same thing; it boots faster but drops apps, so it is only the fallback for API levels that
    # no longer publish `default`.
    for variant in default aosp_atd; do
        SYSTEM_IMAGE="$(list_images "$packages" "android-[0-9]+;${variant}" | tail -1)"
        if [ -n "$SYSTEM_IMAGE" ]; then
            return
        fi
    done

    echo "No AOSP system image found for ${HOST_ABI}. Set SYSTEM_IMAGE to one of:" >&2
    list_images "$packages" "[^;]+;[^;]+" | sed 's/^/    /' >&2
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

# An AVD outlives the image it was created with: uninstalling that image, or moving to a fresh SDK,
# leaves the AVD pointing at a directory that is gone, which the emulator reports as a missing kernel.
# The AVD records the image as a path relative to the SDK root, so reinstalling it is a rename away.
reinstall_missing_system_image() {
    local config sysdir
    config="$ANDROID_USER_HOME/avd/${AVD_NAME}.avd/config.ini"
    # An AVD kept somewhere else has no config.ini here, which is an answer rather than a failure.
    sysdir="$(sed -n 's/^image\.sysdir\.1=//p' "$config" 2>/dev/null | tail -1 || true)"

    if [ -z "$sysdir" ] || [ -d "$ANDROID_HOME/$sysdir" ]; then
        return
    fi

    SYSTEM_IMAGE="$(echo "${sysdir%/}" | tr '/' ';')"
    ensure_system_image
}

ensure_avd() {
    if avdmanager list avd 2>/dev/null | grep -qE "^\s*Name:\s+${AVD_NAME}\s*\$"; then
        reinstall_missing_system_image
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
