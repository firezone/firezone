#!/usr/bin/env bash

# Build script for UniFFI iOS bindings with XCFramework
# This builds the Rust library for all iOS/macOS architectures and creates an XCFramework

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Get the repository root (two levels up from scripts/build/)
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Detect host architecture
HOST_ARCH=$(uname -m)
echo "Host architecture: $HOST_ARCH"

# Change to repo root so all paths work correctly
cd "$REPO_ROOT"

echo "Building client-ffi for iOS with UniFFI..."
echo "Repository root: $REPO_ROOT"

# Build mode (release for production)
BUILD_MODE="${BUILD_MODE:-release}"
if [ "$BUILD_MODE" = "release" ]; then
    CARGO_FLAGS="--release"
    BUILD_DIR="release"
else
    CARGO_FLAGS=""
    BUILD_DIR="debug"
fi

echo "Build mode: $BUILD_MODE"

# Change to rust directory for cargo commands
cd "$REPO_ROOT/rust"

# Array to track which targets we successfully built
BUILT_TARGETS=()
BUILT_LIBS=()
BUILT_HEADERS=()

# Function to try building a target
try_build() {
    local target=$1
    local name=$2
    echo "Building for $name ($target)..."
    if cargo build -p client-ffi --target "$target" $CARGO_FLAGS 2>/dev/null; then
        echo "  ✅ Built $target"
        BUILT_TARGETS+=("$target")
        BUILT_LIBS+=("-library" "target/$target/$BUILD_DIR/libconnlib.a")
        BUILT_HEADERS+=("-headers" "$REPO_ROOT/swift/apple/FirezoneNetworkExtension/Connlib/GeneratedUniFfi/connlibFFI.h")
        return 0
    else
        echo "  ⚠️  Skipping $target (not installed)"
        return 1
    fi
}

# Try to build for various targets
try_build "aarch64-apple-ios" "iOS device (ARM64)"

# Only try simulator targets if on the matching host
if [ "$HOST_ARCH" = "x86_64" ]; then
    try_build "x86_64-apple-ios" "iOS Simulator (x86_64)"
elif [ "$HOST_ARCH" = "arm64" ]; then
    try_build "aarch64-apple-ios-sim" "iOS Simulator (ARM64)"
fi

# Try both macOS targets
try_build "x86_64-apple-darwin" "macOS (x86_64)"
try_build "aarch64-apple-darwin" "macOS (ARM64)"

if [ ${#BUILT_TARGETS[@]} -eq 0 ]; then
    echo "❌ No targets could be built. Please install iOS/macOS targets:"
    echo "   rustup target add aarch64-apple-ios"
    echo "   rustup target add aarch64-apple-ios-sim  # For M1/M2 Macs"
    echo "   rustup target add x86_64-apple-ios       # For Intel Macs"
    echo "   rustup target add aarch64-apple-darwin"
    echo "   rustup target add x86_64-apple-darwin"
    exit 1
fi

# Use the first successfully built target for generating bindings
FIRST_TARGET="${BUILT_TARGETS[0]}"
echo ""
echo "Using $FIRST_TARGET for generating Swift bindings..."

# Generate Swift bindings
cargo run --bin uniffi-bindgen -- generate \
    --library "target/$FIRST_TARGET/$BUILD_DIR/libconnlib.a" \
    --language swift \
    --out-dir "$REPO_ROOT/swift/apple/FirezoneNetworkExtension/Connlib/GeneratedUniFfi"

# Only create XCFramework if we have multiple targets
if [ ${#BUILT_TARGETS[@]} -gt 1 ]; then
    echo ""
    echo "Creating XCFramework with ${#BUILT_TARGETS[@]} architectures..."
    # Create XCFramework combining all built architectures
    xcodebuild -create-xcframework \
        "${BUILT_LIBS[@]}" \
        "${BUILT_HEADERS[@]}" \
        -output "$REPO_ROOT/swift/apple/FirezoneNetworkExtension/Connlib.xcframework"
    
    echo "✅ XCFramework created at $REPO_ROOT/swift/apple/FirezoneNetworkExtension/Connlib.xcframework"
else
    echo "⚠️  Only one architecture built, skipping XCFramework creation"
fi

echo ""
echo "✅ Build complete!"
echo ""
echo "Built targets:"
for target in "${BUILT_TARGETS[@]}"; do
    echo "  - $target"
done
echo ""
echo "Generated files:"
echo "  - Swift bindings: swift/apple/FirezoneNetworkExtension/Connlib/GeneratedUniFfi/connlib.swift"
if [ ${#BUILT_TARGETS[@]} -gt 1 ]; then
    echo "  - XCFramework: swift/apple/FirezoneNetworkExtension/Connlib.xcframework"
fi
echo ""
echo "Next steps:"
if [ ${#BUILT_TARGETS[@]} -gt 1 ]; then
    echo "1. Add Connlib.xcframework to your Xcode project"
else
    echo "1. Link the built library to your Xcode project"
fi
echo "2. Add the generated connlib.swift file to your project"
echo "3. Build and test with the new AdapterUniFfi implementation"