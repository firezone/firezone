#!/usr/bin/env bash
# Shared helpers for putting a local device into the states an X.509-managed device can be in.
# shellcheck disable=SC2034 # sourced by the tasks, which use these

DPC_PACKAGE="dev.firezone.dpc"
DPC_ADMIN="${DPC_PACKAGE}/${DPC_PACKAGE}.AdminReceiver"
APP_PACKAGE="dev.firezone.android"

certificate_dir() {
    echo "${XDG_CACHE_HOME:-${HOME}/.cache}/firezone/x509"
}

# A mise too old to parse the `#USAGE` spec passes `--flag` through as a positional argument
# and sets no `usage_` variable, which would silently run the task without the flag.
require_parsed_flags() {
    local argument variable value
    for argument in "$@"; do
        case "$argument" in
        --*)
            variable="usage_$(echo "${argument#--}" | cut -d= -f1 | tr '-' '_')"
            value="${argument#*=}"
            if [ "$value" = "$argument" ]; then
                value=true
            fi
            if [ -z "${!variable:-}" ]; then
                echo "error: ${argument} reached the task unparsed: this mise did not read the #USAGE flags." >&2
                echo "       Update mise, or pass the flag as an environment variable instead, e.g.:" >&2
                echo "           ${variable}=${value} mise run <task>" >&2
                exit 1
            fi
            ;;
        esac
    done
}

require_adb() {
    command -v adb >/dev/null || {
        echo "error: adb is not on PATH; run 'mise run //kotlin/android:setup' first" >&2
        exit 1
    }

    local state
    state="$(adb get-state 2>&1)" || {
        echo "error: no usable device: ${state}" >&2
        exit 1
    }
}

# The user the DPC owns: a work profile when `provision --work-profile` created one, and the
# device's own user otherwise. Everything downstream targets it, so a task reads the same whichever
# topology is in place.
managed_user() {
    # `adb shell` merges the remote command's complaints into stdout, where the pipeline below
    # would swallow them, so a failed listing has to be reported before anything filters it.
    local owners
    owners="$(adb shell dpm list-owners 2>&1)" || {
        echo "error: 'adb shell dpm list-owners' failed:" >&2
        echo "${owners}" >&2
        exit 1
    }

    echo "${owners}" |
        tr -d '\r' |
        sed -n "s/^User  *\([0-9][0-9]*\):.*${DPC_PACKAGE}.*/\1/p" |
        head -1
}

require_owner() {
    local owned
    owned="$(managed_user)" || exit

    if [ -z "${owned}" ]; then
        echo "error: ${DPC_PACKAGE} owns no user on this device" >&2
        echo "       run 'mise run //kotlin/android:managed-device:provision' first" >&2
        exit 1
    fi
}

find_apk() {
    find ../../app/build/outputs/apk -type f -name "$1" -exec ls -t {} + 2>/dev/null | head -1 || true
}

# Installing a key pair and pushing managed configuration are owner-only APIs that no `adb` command
# exposes, so the DPC makes the calls and reports back through the broadcast's result.
provision() {
    local out
    # FLAG_INCLUDE_STOPPED_PACKAGES: a freshly installed app receives no broadcast otherwise.
    out="$(adb shell am broadcast --user "$(managed_user)" -f 0x00000020 -n "${DPC_PACKAGE}/.ProvisionReceiver" "$@")"

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
