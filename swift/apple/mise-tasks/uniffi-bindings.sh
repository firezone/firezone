#!/usr/bin/env bash
set -euo pipefail

# Validate required tools
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed." >&2
    echo "On macOS, install it with: brew install jq" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="$(cd "${SCRIPT_DIR}/../../../rust" && pwd)"
if ! RUST_TARGET_DIR="$(cd "${RUST_DIR}" && cargo metadata --format-version 1 | jq -r .target_directory)"; then
    echo "Error: failed to determine Rust target directory using 'cargo metadata' in '${RUST_DIR}'." >&2
    echo "Please ensure Rust and Cargo are installed, and that the Rust project in '${RUST_DIR}' is valid." >&2
    exit 1
fi
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

# The bindings are delivered via bridging header instead of a Clang module, so the
# canImport block must go; libconnlib.a carries one binding set per UniFFI namespace.
for namespace in connlib x509claims; do
    generated_swift="${GENERATED_DIR}/${namespace}.swift"
    if [ -f "${generated_swift}" ]; then
        sed -i.bak "/#if canImport(${namespace}FFI)/,/#endif/s/^/\/\/ /" "${generated_swift}"
        # FIXME: remove this workaround when 0.31.1 gets upgraded
        sed -i.bak 's/^\([[:space:]]*\)static let vtablePtr:/\1nonisolated(unsafe) static let vtablePtr:/' "${generated_swift}"
        rm -f "${generated_swift}.bak"
    fi
done

echo "UniFFI bindings generated"
