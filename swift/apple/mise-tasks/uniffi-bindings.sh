#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="$(cd "${SCRIPT_DIR}/../../../rust" && pwd)"
RUST_TARGET_DIR="${RUST_DIR}/target"
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
