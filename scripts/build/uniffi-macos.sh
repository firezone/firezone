#!/usr/bin/env bash

# Build script for UniFFI macOS bindings
# This builds the Rust library and generates Swift bindings for macOS development

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Get the repository root (two levels up from scripts/build/)
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Detect host architecture
HOST_ARCH=$(uname -m)
if [ "$HOST_ARCH" = "arm64" ]; then
    MACOS_TARGET="aarch64-apple-darwin"
    echo "Detected ARM64 (Apple Silicon) Mac"
elif [ "$HOST_ARCH" = "x86_64" ]; then
    MACOS_TARGET="x86_64-apple-darwin"
    echo "Detected x86_64 (Intel) Mac"
else
    echo "Unknown architecture: $HOST_ARCH"
    exit 1
fi

# Allow overriding with environment variable or argument
if [ -n "${TARGET:-}" ]; then
    MACOS_TARGET="$TARGET"
    echo "Using specified target: $MACOS_TARGET"
elif [ $# -ge 1 ]; then
    MACOS_TARGET="$1"
    echo "Using specified target: $MACOS_TARGET"
fi

# Build mode (debug is faster for development)
BUILD_MODE="${BUILD_MODE:-debug}"
if [ "$BUILD_MODE" = "release" ]; then
    CARGO_FLAGS="--release"
    BUILD_DIR="release"
    echo "Building in release mode"
else
    CARGO_FLAGS=""
    BUILD_DIR="debug"
    echo "Building in debug mode (faster for development)"
fi

echo "Building client-ffi for macOS..."
echo "Repository root: $REPO_ROOT"
echo "Target: $MACOS_TARGET"

# Change to rust directory for cargo commands
cd "$REPO_ROOT/rust"

# Build for macOS (current host architecture by default)
echo "Building for macOS ($MACOS_TARGET)..."
cargo build -p client-ffi --target "$MACOS_TARGET" $CARGO_FLAGS

# Generate Swift bindings (using the just-built library)
echo "Generating Swift bindings..."
cargo run --bin uniffi-bindgen -- generate \
    --library "target/$MACOS_TARGET/$BUILD_DIR/libconnlib.dylib" \
    --language swift \
    --out-dir "$REPO_ROOT/swift/apple/FirezoneNetworkExtension/Connlib/GeneratedUniFfi"

echo ""
echo "✅ Build complete!"
echo ""
echo "Generated files:"
echo "  - Rust library: rust/target/$MACOS_TARGET/$BUILD_DIR/libconnlib.dylib"
echo "  - Swift bindings: swift/apple/FirezoneNetworkExtension/Connlib/GeneratedUniFfi/connlib.swift"
echo "  - C header: swift/apple/FirezoneNetworkExtension/Connlib/GeneratedUniFfi/connlibFFI.h"
echo ""
echo "To test in macOS app:"
echo "  1. Open swift/apple/Firezone.xcodeproj in Xcode"
echo "  2. Add the generated connlib.swift to your project (if not already added)"
echo "  3. Link against libconnlib.dylib"
echo "  4. Build and run"
echo ""
echo "For release build, run: BUILD_MODE=release $0"
echo "For specific target: $0 x86_64-apple-darwin  # or aarch64-apple-darwin"