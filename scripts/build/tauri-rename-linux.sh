#!/usr/bin/env bash
#
# Runs from `rust/gui-client` or `rust/tauri-client`

set -euox pipefail

# For debugging
ls "$TARGET_DIR/release" "$TARGET_DIR/release/bundle/deb" "$TARGET_DIR/release/bundle/rpm"

# In release mode the name comes from tauri.conf.json
# Using a glob for the source, there will only be one deb anyway
cp "$TARGET_DIR/release/bundle/deb/firezone-client-gui*.deb" "$BINARY_DEST_PATH.deb"
cp "$TARGET_DIR/release/bundle/rpm/firezone-client-gui*.rpm" "$BINARY_DEST_PATH.rpm"

function make_hash() {
    sha256sum "$1" >"$1.sha256sum.txt"
}

make_hash "$BINARY_DEST_PATH.deb"
make_hash "$BINARY_DEST_PATH.rpm"
