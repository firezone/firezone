# shellcheck shell=bash

# Helpers shared by the `work-profile:*` tasks next to this file.
#
# Sourced, never run: it carries no `#MISE description=` line and is not executable, so mise does not
# offer it as a task, and it leaves `set -euo pipefail` to the task that sources it.

# Where `//:x509:gen-certificate` leaves the certificate it packs, by the name it stored it under.
client_certificate_path() {
    printf '%s/firezone/x509/%s.p12' "${XDG_CACHE_HOME:-${HOME}/.cache}" "$1"
}

# Issuing belongs to `//:x509:gen-certificate`, so the work-profile tasks only ever find one. Which
# claims it carries is decided there, by the subcommand that issued it.
require_client_certificate() {
    local p12="$1"

    if [ -f "$p12" ]; then
        return
    fi

    echo "error: ${p12} does not exist" >&2
    echo >&2
    echo "Issue a certificate first:" >&2
    echo >&2
    echo "    mise run //:x509:create-ca" >&2
    echo "    mise run //:x509:gen-certificate device" >&2
    echo >&2
    echo "or, for one that carries an actor as well:" >&2
    echo >&2
    echo "    mise run //:x509:gen-certificate user --email <email> --account-id <account-id>" >&2
    exit 1
}

# `kotlin/android/mise.toml` resolves `ANDROID_HOME` and puts the SDK's tool directories on `PATH`,
# so a tool missing here is one the SDK does not have installed rather than one `PATH` cannot see.
require_sdk_tool() {
    local tool="$1"

    if command -v "$tool" >/dev/null 2>&1; then
        return
    fi

    echo "${tool} not found under ${ANDROID_HOME:-the Android SDK}." >&2
    echo "Install it with 'mise run //kotlin/android:setup-sdk'." >&2
    exit 1
}

# Reaching into another user, to install into it or to read its storage, needs
# INTERACT_ACROSS_USERS_FULL, which the shell user does not hold on these images. The emulator runs
# userdebug builds (see boot.sh) precisely so restarting adbd as root is available.
adb_root() {
    if [ "$(adb shell id -u 2>/dev/null | tr -d '\r')" = "0" ]; then
        return 0
    fi

    if ! adb root >/dev/null 2>&1; then
        return 1
    fi

    # Restarting adbd drops the connection for a moment.
    adb wait-for-device
}

# The ABI to build for and to boot an emulator with. Fails on anything else so the caller can say
# what to do about it, which differs per task.
host_abi() {
    case "$(uname -m)" in
    x86_64 | amd64)
        echo "x86_64"
        ;;
    arm64 | aarch64)
        echo "arm64-v8a"
        ;;
    *)
        return 1
        ;;
    esac
}

# FLAG_MANAGED_PROFILE is 0x20 in the hex flags `pm list users` prints per user.
work_profile_user() {
    adb shell pm list users 2>/dev/null |
        tr -d '\r' |
        sed -n 's/.*UserInfo{\([0-9][0-9]*\):[^:]*:\([0-9a-fA-F][0-9a-fA-F]*\)}.*/\1 \2/p' |
        while read -r id flags; do
            if [ $((0x$flags & 0x20)) -ne 0 ]; then
                echo "$id"
            fi
        done |
        head -1
}

# The profile the tasks after 'work-profile:create' operate on. Runs in a command substitution, so it
# reports the failure and leaves the `exit` to the call site.
require_work_profile_user() {
    local user_id
    user_id="${WORK_PROFILE_USER:-$(work_profile_user || true)}"

    if [ -z "$user_id" ]; then
        echo "No work profile found. Is the emulator running?" >&2
        echo "Create one with 'mise run //kotlin/android:work-profile:create'." >&2
        return 1
    fi

    echo "$user_id"
}

# The emulator advertises a hardware keyboard, which makes Android hide the on-screen one and wait
# for the host's. Anything driven by hand needs the on-screen keyboard back. The setting is per user,
# so a work profile does not inherit what user 0 has.
show_soft_keyboard() {
    if [ -n "${1:-}" ]; then
        adb shell settings --user "$1" put secure show_ime_with_hard_keyboard 1
    else
        adb shell settings put secure show_ime_with_hard_keyboard 1
    fi
}

# Where 'work-profile:build-dpc' keeps its checkout and where 'work-profile:create' expects the APK.
testdpc_dir() {
    echo "${TESTDPC_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/firezone/android-testdpc}"
}

# `bazel build testdpc` signs its output with a debug key and leaves it under the `bazel-bin`
# convenience symlink in the checkout.
testdpc_apk() {
    echo "$(testdpc_dir)/bazel-bin/testdpc.apk"
}
