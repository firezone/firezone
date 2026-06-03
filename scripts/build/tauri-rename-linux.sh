#!/usr/bin/env bash
#
# Runs from `rust/gui-client` or `rust/tauri-client`

set -euox pipefail

# For debugging
ls "$TARGET_DIR/release" "$TARGET_DIR/debian" "$TARGET_DIR/generate-rpm"

# Linux packages are produced by cargo-deb (`target/debian/`) and
# cargo-generate-rpm (`target/generate-rpm/`); the package name comes
# from the `[package.metadata.deb]` / `[package.metadata.generate-rpm]`
# blocks in the gui-client manifest. Globbing the source — there's only
# one of each anyway.
cp $TARGET_DIR/debian/firezone-client-gui*.deb "$BINARY_DEST_PATH.deb"
cp $TARGET_DIR/generate-rpm/firezone-client-gui*.rpm "$BINARY_DEST_PATH.rpm"

function make_hash() {
    sha256sum "$1" >"$1.sha256sum.txt"
}

make_hash "$BINARY_DEST_PATH.deb"
make_hash "$BINARY_DEST_PATH.rpm"
