#!/usr/bin/env bash
#MISE description="Install required NDK version (must match build.gradle.kts)"
set -euo pipefail

: "${ANDROID_HOME:?ANDROID_HOME must point to your Android SDK root}"

# Prefer the cmdline-tools sdkmanager; the legacy `tools/bin/sdkmanager` that may
# shadow it on PATH requires Java <= 10 and crashes on modern JDKs.
sdkmanager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
if [[ ! -x "$sdkmanager" ]]; then
    sdkmanager="sdkmanager"
fi

"$sdkmanager" --sdk_root="$ANDROID_HOME" "ndk;${NDK_VERSION}"
