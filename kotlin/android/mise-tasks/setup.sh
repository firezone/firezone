#!/usr/bin/env bash
#MISE description="Install all dependencies needed to build the Android client"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

# ANDROID_HOME and NDK_VERSION come from kotlin/android/mise.toml [env], which also puts the SDK's
# tool directories on PATH.
RUST_TARGETS=(
    aarch64-linux-android
    armv7-linux-androideabi
    i686-linux-android
    x86_64-linux-android
)

echo "==> Installing mise tool versions (Java, ktlint)..."
mise install

echo "==> Installing the Android SDK command-line tools..."
"${SCRIPT_DIR}/setup-sdk.sh"

echo "==> Installing NDK ${NDK_VERSION}..."
"${SCRIPT_DIR}/setup-ndk.sh"

# --- local.properties ---
if [ ! -f local.properties ]; then
    echo "==> Creating local.properties..."
    echo "sdk.dir=${ANDROID_HOME}" >local.properties
else
    echo "==> local.properties already exists, skipping"
fi

# --- Rust targets ---
# The rust/rust-toolchain.toml pins a specific version; targets must be added to that toolchain.
RUST_TOOLCHAIN=$(grep '^channel' "${SCRIPT_DIR}/../../../rust/rust-toolchain.toml" | sed 's/.*"\(.*\)".*/\1/')
echo "==> Installing Rust Android targets for toolchain ${RUST_TOOLCHAIN}..."
rustup target add --toolchain "${RUST_TOOLCHAIN}" "${RUST_TARGETS[@]}"

echo ""
echo "==> Setup complete! Run 'mise run build' to build the debug APK."
