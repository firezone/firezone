#!/usr/bin/env bash
#MISE description="Build debug APK (host ABI for fast local iteration; all ABIs when CI=1 for cross-ABI compile-check coverage)"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

# On CI, build every ABI so a regression on any one of them fails the debug build.
# Locally, build only the host ABI to keep iteration fast — Android Studio launches and
# the install-phone/install-emulator tasks already pass `android.injected.build.abi`
# explicitly, so this only narrows the otherwise-unscoped `mise run build`.
if [ -n "${CI:-}" ]; then
    exec ./gradlew assembleDebug
fi

case "$(uname -m)" in
x86_64 | amd64) host_abi=x86_64 ;;
arm64 | aarch64) host_abi=arm64-v8a ;;
*)
    echo "Unsupported host arch $(uname -m); building all ABIs." >&2
    exec ./gradlew assembleDebug
    ;;
esac

exec ./gradlew assembleDebug "-Pandroid.injected.build.abi=$host_abi"
