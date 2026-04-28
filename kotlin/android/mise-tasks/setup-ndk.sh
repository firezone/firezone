#!/usr/bin/env bash
#MISE description="Install required NDK version (must match build.gradle.kts)"
set -euo pipefail

sdkmanager "ndk;${NDK_VERSION}"
