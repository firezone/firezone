#!/usr/bin/env bash
#MISE description="Install all dependencies needed to build the Android client"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

# NDK_VERSION and the ANDROID_CMD_TOOLS_* versions come from kotlin/android/mise.toml [env].
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
        # Google ships separate macOS archives per architecture since command-line tools 22.0.
        CMD_TOOLS_PLATFORM="mac_$(uname -m)"
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

# sdkmanager expects the directory to be named "latest".
CMD_TOOLS_DIR="$ANDROID_HOME/cmdline-tools/latest"
INSTALLED_REVISION="$(sed -n 's/^Pkg\.Revision=//p' "$CMD_TOOLS_DIR/source.properties" 2>/dev/null || true)"

if [ "$INSTALLED_REVISION" = "$ANDROID_CMD_TOOLS_REVISION" ]; then
    echo "==> Android command-line tools ${ANDROID_CMD_TOOLS_REVISION} already installed"
else
    echo "==> Installing Android command-line tools ${ANDROID_CMD_TOOLS_REVISION}..."

    TOOLS_ZIP="$(mktemp)"
    TOOLS_UNPACK_DIR="$(mktemp -d)"
    trap 'rm -rf "$TOOLS_ZIP" "$TOOLS_UNPACK_DIR"' EXIT

    curl -fsSL -o "$TOOLS_ZIP" \
        "https://dl.google.com/android/repository/commandlinetools-${CMD_TOOLS_PLATFORM}-${ANDROID_CMD_TOOLS_VERSION}_latest.zip"
    unzip -qo "$TOOLS_ZIP" -d "$TOOLS_UNPACK_DIR"

    # `mv` into an existing `latest` would nest inside it, so unpack aside and swap.
    mkdir -p "$ANDROID_HOME/cmdline-tools"
    rm -rf "$CMD_TOOLS_DIR"
    mv "$TOOLS_UNPACK_DIR/cmdline-tools" "$CMD_TOOLS_DIR"
fi

if ! command -v sdkmanager &>/dev/null; then
    echo ""
    echo "    Add these to your shell profile (~/.bashrc or ~/.zshrc):"
    echo ""
    echo "      export ANDROID_HOME=\"$ANDROID_HOME\""
    echo "      export PATH=\"\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$PATH\""
    echo ""
fi

export PATH="$CMD_TOOLS_DIR/bin:$ANDROID_HOME/platform-tools:$PATH"

if ! sdkmanager --version >/dev/null 2>&1; then
    echo "sdkmanager is not runnable; check JAVA_HOME and the SDK install." >&2
    exit 1
fi

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
