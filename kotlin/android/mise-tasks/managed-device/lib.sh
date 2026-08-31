#!/usr/bin/env bash
# Shared helpers for putting a local device into the states an X.509-managed device can be in.
# shellcheck disable=SC2034 # sourced by the tasks, which use these

DPC_PACKAGE="dev.firezone.dpc"
DPC_ADMIN="${DPC_PACKAGE}/${DPC_PACKAGE}.AdminReceiver"
APP_PACKAGE="dev.firezone.android"

certificate_dir() {
    echo "${XDG_CACHE_HOME:-${HOME}/.cache}/firezone/x509"
}

require_adb() {
    command -v adb >/dev/null || {
        echo "error: adb is not on PATH; run 'mise run //kotlin/android:setup' first" >&2
        exit 1
    }

    adb get-state >/dev/null 2>&1 || {
        echo "error: no device is attached" >&2
        exit 1
    }
}

require_device_owner() {
    if ! adb shell dpm list-owners | grep -q "$DPC_PACKAGE"; then
        echo "error: ${DPC_PACKAGE} does not own this device" >&2
        echo "       run 'mise run //kotlin/android:managed-device:provision' first" >&2
        exit 1
    fi
}

# Installing a key pair and pushing managed configuration are owner-only APIs that no `adb` command
# exposes, so the DPC makes the calls and reports back through the broadcast's result.
provision() {
    local out
    # FLAG_INCLUDE_STOPPED_PACKAGES: a freshly installed app receives no broadcast otherwise.
    out="$(adb shell am broadcast -f 0x00000020 -n "${DPC_PACKAGE}/.ProvisionReceiver" "$@")"

    case "$out" in
    *"result=0"*)
        echo "    ${out##*data=}"
        ;;
    *)
        echo "${out}" >&2
        exit 1
        ;;
    esac
}
