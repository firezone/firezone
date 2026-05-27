#!/usr/bin/env bash
#MISE description="Install required NDK version (must match build.gradle.kts)"
set -euo pipefail

: "${ANDROID_HOME:?ANDROID_HOME must point to your Android SDK root}"
sdkmanager --sdk_root="$ANDROID_HOME" "ndk;${NDK_VERSION}"
