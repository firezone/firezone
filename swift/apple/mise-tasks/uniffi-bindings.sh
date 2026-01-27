#!/usr/bin/env bash
set -euo pipefail

# Validate required tools
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed." >&2
    echo "Install it with: brew install jq" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="$(cd "${SCRIPT_DIR}/../../../rust" && pwd)"
RUST_TARGET_DIR="$(cd "${RUST_DIR}" && cargo metadata --format-version 1 | jq -r .target_directory)"
GENERATED_DIR="${SCRIPT_DIR}/../FirezoneNetworkExtension/Connlib/Generated"

echo "Generating UniFFI bindings..."
mkdir -p "${GENERATED_DIR}"

cd "${RUST_DIR}"
cargo build -p client-ffi
cargo run -p uniffi-bindgen -- generate \
    --library "${RUST_TARGET_DIR}/debug/libconnlib.a" \
    --language swift \
    --out-dir "${GENERATED_DIR}"

rm -f "${GENERATED_DIR}"/*.modulemap

if [ -f "${GENERATED_DIR}/connlib.swift" ]; then
    sed -i.bak '/#if canImport(connlibFFI)/,/#endif/s/^/\/\/ /' "${GENERATED_DIR}/connlib.swift"
    rm -f "${GENERATED_DIR}/connlib.swift.bak"
fi

echo "UniFFI bindings generated"
