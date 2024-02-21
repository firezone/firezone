#!/usr/bin/env bash
set -euo pipefail

# For debugging
ls ../target/release ../target/release/bundle/msi

# Used for release artifact
# In release mode the name comes from tauri.conf.json
cp "../target/release/*.exe" "$BINARY_DEST_PATH-x64.exe"
cp "../target/release/bundle/msi/*.msi" "$BINARY_DEST_PATH-x64.msi"
cp "../target/release/firezone_windows_client.pdb" "$BINARY_DEST_PATH-x64.pdb"

sha256sum "$BINARY_DEST_PATH-x64.exe"> "$BINARY_DEST_PATH-x64.exe.sha256sum.txt"
sha256sum "$BINARY_DEST_PATH-x64.msi"> "$BINARY_DEST_PATH-x64.msi.sha256sum.txt"
sha256sum "$BINARY_DEST_PATH-x64.pdb"> "$BINARY_DEST_PATH-x64.pdb.sha256sum.txt"

# This might catch regressions in #3384, depending how CI runners
# handle exit codes
git diff --exit-code
