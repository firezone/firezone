#!/usr/bin/env bash
#MISE description="Build the debug APK and install it into the work profile"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

cd "${SCRIPT_DIR}/../.."

PACKAGE="dev.firezone.android"

if ! HOST_ABI="$(host_abi)"; then
    echo "Unsupported host arch: $(uname -m)." >&2
    exit 1
fi

require_sdk_tool adb

user_id="$(require_work_profile_user)" || exit 1

# `installDebug` targets user 0, so the APK is built and then installed into the profile by hand.
echo "==> Building the debug APK (${HOST_ABI} only)..."
./gradlew assembleDebug "-Pandroid.injected.build.abi=$HOST_ABI"

# Newest rather than first: a stale APK from an earlier all-ABI build sorts ahead of the one that
# was just built, and installing that is indistinguishable from the build not having taken effect.
# The whole tree rather than the `debug` directory alone, so a flavour nesting it deeper still works.
# `-exec ... +` runs nothing when nothing matches, where piping into `xargs ls -t` would list the
# working directory instead.
apk="$(find app/build/outputs/apk -type f -name '*.apk' -exec ls -t {} + 2>/dev/null | head -1 || true)"

if [ -z "$apk" ]; then
    echo "The build produced no APK under app/build/outputs/apk. What is there:" >&2
    find app/build/outputs -maxdepth 3 2>/dev/null | sed 's/^/    /' >&2 || true
    exit 1
fi

echo "==> Force-stopping any running instance of ${PACKAGE} in user ${user_id}..."
adb shell am force-stop --user "$user_id" "$PACKAGE"

echo "==> Installing ${apk} into user ${user_id}..."
adb install -r -g --user "$user_id" "$apk"

echo
echo "==> Installed. Next: mise run //kotlin/android:work-profile:certificate"
