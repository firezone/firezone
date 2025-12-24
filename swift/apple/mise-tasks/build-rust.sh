#!/bin/bash
set -euo pipefail

# Error handler
trap 'echo "ERROR: Build script failed at line $LINENO" >&2' ERR

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="$SCRIPT_DIR/../../../rust"

# Sanitize the environment to prevent Xcode's shenanigans from leaking
# into our highly evolved Rust-based build system.
for var in $(env | awk -F= '{print $1}'); do
    if [[ "$var" != "HOME" ]] &&
        [[ "$var" != "MACOSX_DEPLOYMENT_TARGET" ]] &&
        [[ "$var" != "IPHONEOS_DEPLOYMENT_TARGET" ]] &&
        [[ "$var" != "USER" ]] &&
        [[ "$var" != "LOGNAME" ]] &&
        [[ "$var" != "TERM" ]] &&
        [[ "$var" != "PWD" ]] &&
        [[ "$var" != "SHELL" ]] &&
        [[ "$var" != "TMPDIR" ]] &&
        [[ "$var" != "XPC_FLAGS" ]] &&
        [[ "$var" != "XPC_SERVICE_NAME" ]] &&
        [[ "$var" != "PLATFORM_NAME" ]] &&
        [[ "$var" != "CONFIGURATION" ]] &&
        [[ "$var" != "NATIVE_ARCH" ]] &&
        [[ "$var" != "ONLY_ACTIVE_ARCH" ]] &&
        [[ "$var" != "ARCHS" ]] &&
        [[ "$var" != "SDKROOT" ]] &&
        [[ "$var" != "OBJROOT" ]] &&
        [[ "$var" != "SYMROOT" ]] &&
        [[ "$var" != "SRCROOT" ]] &&
        [[ "$var" != "TARGETED_DEVICE_FAMILY" ]] &&
        [[ "$var" != "RUSTC_WRAPPER" ]] &&
        [[ "$var" != "RUST_TOOLCHAIN" ]] &&
        [[ "$var" != "SCCACHE_GCS_BUCKET" ]] &&
        [[ "$var" != "SCCACHE_GCS_RW_MODE" ]] &&
        [[ "$var" != "GOOGLE_CLOUD_PROJECT" ]] &&
        [[ "$var" != "GCP_PROJECT" ]] &&
        [[ "$var" != "GCLOUD_PROJECT" ]] &&
        [[ "$var" != "CLOUDSDK_PROJECT" ]] &&
        [[ "$var" != "CLOUDSDK_CORE_PROJECT" ]] &&
        [[ "$var" != "GOOGLE_GHA_CREDS_PATH" ]] &&
        [[ "$var" != "GOOGLE_APPLICATION_CREDENTIALS" ]] &&
        [[ "$var" != "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE" ]] &&
        [[ "$var" != "ACTIONS_CACHE_URL" ]] &&
        [[ "$var" != "ACTIONS_RUNTIME_TOKEN" ]] &&
        [[ "$var" != "CARGO_INCREMENTAL" ]] &&
        [[ "$var" != "CARGO_TERM_COLOR" ]] &&
        [[ "$var" != "FIREZONE_PACKAGE_VERSION" ]] &&
        [[ "$var" != "CONNLIB_TARGET_DIR" ]]; then
        unset "$var"
    fi
done

# Use pristine path; the PATH from Xcode is polluted with stuff we don't want which can
# confuse rustc.
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$HOME/.cargo/bin:/run/current-system/sw/bin/"

# Parse Xcode environment
PLATFORM_NAME="${PLATFORM_NAME:-macosx}"
CONFIGURATION="${CONFIGURATION:-Debug}"
NATIVE_ARCH="${ARCHS:-${NATIVE_ARCH:-$(uname -m)}}"

# Set target directory - use CONNLIB_TARGET_DIR if set, otherwise default
export CARGO_TARGET_DIR="${CONNLIB_TARGET_DIR:-$RUST_DIR/target}"

echo "========================================="
echo "Building Connlib for Xcode"
echo "Platform: $PLATFORM_NAME"
echo "Configuration: $CONFIGURATION"
echo "Architecture: $NATIVE_ARCH"
echo "Target Directory: $CARGO_TARGET_DIR"
echo "========================================="

# Determine Rust targets based on platform and architecture
TARGETS=()
case "$PLATFORM_NAME" in
macosx)
    if [[ "$CONFIGURATION" == "Release" ]] || [[ "$CONFIGURATION" == "Profile" ]] || [[ -z "$NATIVE_ARCH" ]]; then
        # Build universal binary for Release and Profile
        TARGETS=("aarch64-apple-darwin" "x86_64-apple-darwin")
    else
        # Build only for native arch in Debug
        if [[ "$NATIVE_ARCH" == "arm64" ]]; then
            TARGETS=("aarch64-apple-darwin")
        elif [[ "$NATIVE_ARCH" == "x86_64" ]]; then
            TARGETS=("x86_64-apple-darwin")
        else
            echo "ERROR: Unsupported native arch for $PLATFORM_NAME: $NATIVE_ARCH" >&2
            exit 1
        fi
    fi
    ;;
iphoneos)
    TARGETS=("aarch64-apple-ios")
    ;;
iphonesimulator)
    if [[ "$NATIVE_ARCH" == "arm64" ]]; then
        TARGETS=("aarch64-apple-ios-sim")
    elif [[ "$NATIVE_ARCH" == "x86_64" ]]; then
        TARGETS=("x86_64-apple-ios")
    else
        echo "ERROR: Unsupported native arch for $PLATFORM_NAME: $NATIVE_ARCH" >&2
        exit 1
    fi
    ;;
*)
    echo "ERROR: Unknown platform: $PLATFORM_NAME" >&2
    exit 1
    ;;
esac

# Prepare cargo build flags
if [ "$CONFIGURATION" = "Release" ] || [ "$CONFIGURATION" = "Profile" ]; then
    CARGO_BUILD_FLAGS="--release"
    BUILD_DIR="release"
else
    CARGO_BUILD_FLAGS=""
    BUILD_DIR="debug"
fi

# Ensure RUSTUP_HOME is set
if [ -z "${RUSTUP_HOME:-}" ] && [ -d "$HOME/.rustup" ]; then
    export RUSTUP_HOME="$HOME/.rustup"
fi

# Ensure Rust targets are installed (from rust directory to use correct toolchain)
cd "$RUST_DIR"
for target in "${TARGETS[@]}"; do
    if ! rustup target list --installed | grep -q "^$target$"; then
        echo "Installing Rust target: $target"
        rustup target add "$target"
    fi
done

# Build Rust library
echo ""
echo "Building Rust library..."

# Build target list for cargo command
target_list=""
for target in "${TARGETS[@]}"; do
    target_list+="--target $target "
done
target_list="${target_list% }"

cd "$RUST_DIR"
cargo build --package client-ffi $target_list $CARGO_BUILD_FLAGS

# Remove any dylib files to ensure static linking
for target in "${TARGETS[@]}"; do
    LIBRARY_PATH="$CARGO_TARGET_DIR/$target/$BUILD_DIR"
    if [ -f "$LIBRARY_PATH/libconnlib.dylib" ]; then
        rm -f "$LIBRARY_PATH/libconnlib.dylib"
    fi
done

# Generate UniFFI bindings
echo ""
echo "Generating UniFFI bindings..."
cd "$SCRIPT_DIR"
./uniffi-bindings.sh

echo ""
echo "✅ Rust library build completed successfully!"
echo "   Built libraries:"
for target in "${TARGETS[@]}"; do
    echo "     - $CARGO_TARGET_DIR/$target/$BUILD_DIR/libconnlib.a"
done
echo "========================================="
