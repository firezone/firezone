# shellcheck shell=bash

# Helpers shared by the `work-profile:*` tasks next to this file.
#
# Sourced, never run: it carries no `#MISE description=` line and is not executable, so mise does not
# offer it as a task, and it leaves `set -euo pipefail` to the task that sources it.

# `ANDROID_SDK_ROOT` is the deprecated spelling of `ANDROID_HOME` that plenty of setups still export.
android_home() {
    ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
    export ANDROID_HOME
}

# `adb` ships with the SDK, which is not on `PATH` by default.
require_adb() {
    android_home
    export PATH="$ANDROID_HOME/platform-tools:$PATH"

    if ! command -v adb >/dev/null 2>&1; then
        echo "adb not found in PATH. Run 'mise run setup' first." >&2
        exit 1
    fi
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

# Where 'work-profile:build-dpc' keeps its checkout and where 'work-profile:create' expects the APK.
testdpc_dir() {
    echo "${TESTDPC_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/firezone/android-testdpc}"
}

# The artifact has been named TestDPC-debug.apk for years, but taking the newest APK under the debug
# output directory survives a rename upstream.
newest_testdpc_apk() {
    find "$(testdpc_dir)/app/build/outputs/apk/debug" -name '*.apk' -type f -print0 2>/dev/null |
        xargs -0 ls -t 2>/dev/null |
        head -1
}
