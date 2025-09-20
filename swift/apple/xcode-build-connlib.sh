#!/bin/bash
set -euo pipefail

# Simple build script for Firezone connlib
# This consolidates the functionality without unnecessary complexity

# Error handler
trap 'echo "ERROR: Build script failed at line $LINENO" >&2' ERR

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="$SCRIPT_DIR/../../rust"
GENERATED_DIR="$SCRIPT_DIR/FirezoneNetworkExtension/Connlib/Generated"

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

# Determine Rust target based on platform and architecture
case "$PLATFORM_NAME" in
    macosx)
        if [ "$NATIVE_ARCH" = "arm64" ]; then
            RUST_TARGET="aarch64-apple-darwin"
        else
            RUST_TARGET="x86_64-apple-darwin"
        fi
        ;;
    iphoneos)
        RUST_TARGET="aarch64-apple-ios"
        ;;
    iphonesimulator)
        if [ "$NATIVE_ARCH" = "arm64" ]; then
            RUST_TARGET="aarch64-apple-ios-sim"
        else
            RUST_TARGET="x86_64-apple-ios"
        fi
        ;;
    *)
        echo "ERROR: Unknown platform: $PLATFORM_NAME" >&2
        exit 1
        ;;
esac

# Prepare cargo build flags
if [ "$CONFIGURATION" = "Release" ]; then
    CARGO_BUILD_FLAGS="--release"
    BUILD_DIR="release"
else
    CARGO_BUILD_FLAGS=""
    BUILD_DIR="debug"
fi

# Setup clean PATH to avoid Xcode pollution
export PATH="$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Ensure RUSTUP_HOME is set
if [ -z "${RUSTUP_HOME:-}" ] && [ -d "$HOME/.rustup" ]; then
    export RUSTUP_HOME="$HOME/.rustup"
fi

# Ensure Rust target is installed
if ! rustup target list --installed | grep -q "^$RUST_TARGET$"; then
    echo "Installing Rust target: $RUST_TARGET"
    rustup target add "$RUST_TARGET"
fi

# Step 1: Build Rust library
echo ""
echo "Step 1/3: Building Rust library for $RUST_TARGET..."
cd "$RUST_DIR"
cargo build --package client-ffi --target "$RUST_TARGET" $CARGO_BUILD_FLAGS

# Remove any dylib files to ensure static linking
LIBRARY_PATH="$CARGO_TARGET_DIR/$RUST_TARGET/$BUILD_DIR"
if [ -f "$LIBRARY_PATH/libconnlib.dylib" ]; then
    rm -f "$LIBRARY_PATH/libconnlib.dylib"
fi

# Step 2: Generate UniFFI bindings
echo ""
echo "Step 2/3: Generating UniFFI bindings..."
mkdir -p "$GENERATED_DIR"

cargo run -p uniffi-bindgen -- generate \
    --library "$LIBRARY_PATH/libconnlib.a" \
    --language swift \
    --out-dir "$GENERATED_DIR"

# Remove module maps (we use bridging header instead)
rm -f "$GENERATED_DIR"/*.modulemap

# Fix imports in generated Swift file to use bridging header
if [ -f "$GENERATED_DIR/connlib.swift" ]; then
    # Comment out the #if canImport(connlibFFI) block
    sed -i.bak '/#if canImport(connlibFFI)/,/#endif/s/^/\/\/ /' "$GENERATED_DIR/connlib.swift"
    rm -f "$GENERATED_DIR/connlib.swift.bak"
fi

# Step 3: Verify generated files
echo ""
echo "Step 3/3: Verifying generated files..."
if [ ! -f "$GENERATED_DIR/connlib.swift" ]; then
    echo "ERROR: Generated Swift file not found" >&2
    exit 1
fi

if [ ! -f "$GENERATED_DIR/connlibFFI.h" ]; then
    echo "ERROR: Generated header file not found" >&2
    exit 1
fi

echo ""
echo "✅ Build completed successfully!"
echo "   Swift bindings: $GENERATED_DIR/connlib.swift"
echo "   C header: $GENERATED_DIR/connlibFFI.h"
echo "   Static library: $LIBRARY_PATH/libconnlib.a"
echo "========================================="