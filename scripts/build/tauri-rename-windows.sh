#!/usr/bin/env bash
set -euo pipefail

# For debugging
ls ../target/release ../target/release/bundle/msi

# Used for release artifact
# In release mode the name comes from tauri.conf.json
# Using a glob for the source, there will only be one exe, msi, and pdb anyway
cp ../target/release/*.exe "$BINARY_DEST_PATH-x64.exe"
cp ../target/release/bundle/msi/*.msi "$BINARY_DEST_PATH-x64.msi"
cp ../target/release/*.pdb "$BINARY_DEST_PATH-x64.pdb"

function make_hash() {
    sha256sum "$1"> "$1.sha256sum.txt"
}

make_hash "$BINARY_DEST_PATH-x64.exe"
make_hash "$BINARY_DEST_PATH-x64.msi"
make_hash "$BINARY_DEST_PATH-x64.pdb"
