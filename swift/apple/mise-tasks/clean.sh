#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
RUST_DIR="${SCRIPT_DIR}/../../../rust"
CONFIGURATION="${CONFIGURATION:-Debug}"

cd "${APPLE_DIR}"

echo "Cleaning Xcode build"
xcodebuild clean \
    -project Firezone.xcodeproj \
    -scheme Firezone \
    -configuration "${CONFIGURATION}" \
    -sdk macosx

echo "Cleaning Rust build artifacts"
cd "${RUST_DIR}/client-ffi" && cargo clean

echo "Removing generated bindings"
rm -rf "${APPLE_DIR}/FirezoneNetworkExtension/Connlib/Generated"
