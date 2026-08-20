#!/usr/bin/env bash
#MISE description="Install required NDK version (must match build.gradle.kts)"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

# Mirrors the SDK resolution order of `resolveNdkDir` in `app/build.gradle.kts` so the
# NDK lands in the SDK the build will look in. `local.properties` is what Android Studio
# writes, so it is often the only place the SDK location is recorded.
sdk_dir="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$sdk_dir" && -f local.properties ]]; then
    # `Properties.load` unescapes the value, so `:`, `=` and `\` reach Gradle without
    # the backslash Android Studio wrote them with.
    sdk_dir="$(awk '/^[[:space:]]*sdk\.dir[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); sub(/\r$/, ""); dir = $0 } END { print dir }' local.properties | sed 's/\\\(.\)/\1/g')"
fi

if [[ -z "$sdk_dir" ]]; then
    echo "Cannot locate the Android SDK. Set ANDROID_HOME or \`sdk.dir\` in local.properties." >&2
    exit 1
fi

# Prefer the cmdline-tools sdkmanager; the legacy `tools/bin/sdkmanager` that may
# shadow it on PATH requires Java <= 10 and crashes on modern JDKs.
sdkmanager="$sdk_dir/cmdline-tools/latest/bin/sdkmanager"
if [[ ! -x "$sdkmanager" ]]; then
    sdkmanager="sdkmanager"
fi

"$sdkmanager" --sdk_root="$sdk_dir" "ndk;${NDK_VERSION}"
