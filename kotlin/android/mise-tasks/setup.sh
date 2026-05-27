#!/usr/bin/env bash
#MISE description="Install all dependencies needed to build the Android client"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

# NDK_VERSION and ANDROID_CMD_TOOLS_VERSION come from kotlin/android/mise.toml [env].
RUST_TARGETS=(
    aarch64-linux-android
    armv7-linux-androideabi
    i686-linux-android
    x86_64-linux-android
)

case "$(uname -s)" in
    Linux)
        CMD_TOOLS_PLATFORM="linux"
        DEFAULT_ANDROID_HOME="$HOME/Android/Sdk"
        ;;
    Darwin)
        CMD_TOOLS_PLATFORM="mac"
        DEFAULT_ANDROID_HOME="$HOME/Library/Android/sdk"
        ;;
    *)
        echo "Unsupported platform: $(uname -s). Install the Android command-line tools manually." >&2
        exit 1
        ;;
esac

echo "==> Installing mise tool versions (Java, ktlint)..."
mise install

# --- Android SDK ---
if [ -z "${ANDROID_HOME:-}" ]; then
    export ANDROID_HOME="${ANDROID_SDK_ROOT:-$DEFAULT_ANDROID_HOME}"
fi

if ! command -v sdkmanager &>/dev/null; then
    echo "==> Installing Android command-line tools..."
    mkdir -p "$ANDROID_HOME/cmdline-tools"

    TOOLS_ZIP="$(mktemp)"
    curl -fsSL -o "$TOOLS_ZIP" \
        "https://dl.google.com/android/repository/commandlinetools-${CMD_TOOLS_PLATFORM}-${ANDROID_CMD_TOOLS_VERSION}_latest.zip"
    unzip -qo "$TOOLS_ZIP" -d "$ANDROID_HOME/cmdline-tools"
    rm "$TOOLS_ZIP"

    # sdkmanager expects the directory to be named "latest"
    mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"

    export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

    echo ""
    echo "    Add these to your shell profile (~/.bashrc or ~/.zshrc):"
    echo ""
    echo "      export ANDROID_HOME=\"$ANDROID_HOME\""
    echo "      export PATH=\"\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$PATH\""
    echo ""
fi

if ! sdkmanager --version >/dev/null 2>&1; then
    echo "sdkmanager is not runnable; check JAVA_HOME and the SDK install." >&2
    exit 1
fi

echo "==> Accepting Android SDK licenses..."
# `yes | sdkmanager` exits non-zero via SIGPIPE once sdkmanager closes stdin.
yes 2>/dev/null | sdkmanager --sdk_root="$ANDROID_HOME" --licenses >/dev/null || true

echo "==> Installing NDK ${NDK_VERSION}..."
"${SCRIPT_DIR}/setup-ndk.sh"

# --- local.properties ---
if [ ! -f local.properties ]; then
    echo "==> Creating local.properties..."
    echo "sdk.dir=${ANDROID_HOME}" > local.properties
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
