#!/usr/bin/env bash
set -euo pipefail

# For debugging
ls ../target/release ../target/release/bundle/deb

# Used for release artifact
# In release mode the name comes from tauri.conf.json
# Using a glob for the source, there will only be one exe and one deb anyway
cp ../target/release/firezone "$BINARY_DEST_PATH"
cp ../target/release/firezone-gui-client.dwp "$BINARY_DEST_PATH.dwp"
cp ../target/release/bundle/deb/*_amd64.deb "$BINARY_DEST_PATH.deb"
# TODO: Debug symbols for Linux

function make_hash() {
    sha256sum "$1" >"$1.sha256sum.txt"
}

# Windows uses x64, Debian amd64. Standardize on x86_64 naming here since that's
# what Rust uses.
make_hash "$BINARY_DEST_PATH"
make_hash "$BINARY_DEST_PATH.dwp"
make_hash "$BINARY_DEST_PATH.deb"

# Test the deb package, since this script is the easiest place to get a release build
sudo dpkg --install "$BINARY_DEST_PATH.deb"

# Debug-print the files. The icons and both binaries should be in here
dpkg --listfiles firezone

# Confirm that both binaries and at least one icon were installed
which firezone firezone-client-tunnel
stat /usr/share/icons/hicolor/512x512/apps/firezone.png

# Make sure the binaries both got built, packaged, and installed, and at least
# know their own names
firezone-client-tunnel --help | grep "Usage: firezone-client-tunnel"
firezone --help | grep "Usage: firezone"
