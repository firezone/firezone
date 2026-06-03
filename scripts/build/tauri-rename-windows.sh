#!/usr/bin/env bash
set -euox pipefail

# For debugging
ls "$TARGET_DIR/release" "$TARGET_DIR/wix"

function make_hash() {
    sha256sum "$1" >"$1.sha256sum.txt"
}

# The MSI is the cargo-wix output (`target/wix/`); always required.
cp "$TARGET_DIR"/wix/*.msi "$BINARY_DEST_PATH.msi"
make_hash "$BINARY_DEST_PATH.msi"

# The standalone exe + debug symbols only exist for real builds
# (cargo emits `firezone-gui-client.exe`). Skip them for stub
# packaging-config runs, where the binaries are placeholders.
if [ -f "$TARGET_DIR/release/firezone-gui-client.exe" ]; then
    cp "$TARGET_DIR/release/firezone-gui-client.exe" "$BINARY_DEST_PATH.exe"
    make_hash "$BINARY_DEST_PATH.exe"
fi
if [ -f "$TARGET_DIR/release/firezone_gui_client.pdb" ]; then
    cp "$TARGET_DIR/release/firezone_gui_client.pdb" "$BINARY_DEST_PATH.pdb"
    make_hash "$BINARY_DEST_PATH.pdb"
fi
