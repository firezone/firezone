#!/usr/bin/env bash
#
# Runs from `rust/gui-client` or `rust/tauri-client`

set -euox pipefail

SERVICE_NAME=firezone-client-ipc

function debug_exit() {
    systemctl status "$SERVICE_NAME"
    exit 1
}

# For debugging
ls "$TARGET_DIR/release" "$TARGET_DIR/release/bundle/deb"

# Used for release artifact
# In release mode the name comes from tauri.conf.json
# Using a glob for the source, there will only be one exe and one deb anyway
cp "$TARGET_DIR/release/firezone-client-gui" "$BINARY_DEST_PATH"
cp "$TARGET_DIR/release/firezone-gui-client.dwp" "$BINARY_DEST_PATH.dwp"
cp "$TARGET_DIR/release/bundle/deb/firezone-client-gui.deb" "$BINARY_DEST_PATH.deb"
cp "$TARGET_DIR/../gui-client/firezone-client-gui.rpm" "$BINARY_DEST_PATH.rpm"
# TODO: Debug symbols for Linux

function make_hash() {
    sha256sum "$1" >"$1.sha256sum.txt"
}

# Windows calls it `x64`, Debian `amd64`. Standardize on `x86_64` here since that's
# what Rust uses.
make_hash "$BINARY_DEST_PATH"
make_hash "$BINARY_DEST_PATH.dwp"
make_hash "$BINARY_DEST_PATH.deb"
make_hash "$BINARY_DEST_PATH.rpm"

if [[ ! "$SKIP_PACKAGE_TEST" == "true" ]]; then
    # Test the deb package, since this script is the easiest place to get a release build
    DEB_PATH=$(realpath "$BINARY_DEST_PATH.deb")
    sudo apt-get install "$DEB_PATH"

    # Debug-print the files. The icons and both binaries should be in here
    dpkg --listfiles firezone-client-gui
    # Print the deps
    dpkg --info "$DEB_PATH"

    # Confirm that both binaries and at least one icon were installed
    which firezone-client-gui firezone-client-ipc
    stat /usr/share/icons/hicolor/512x512/apps/firezone-client-gui.png

    # Make sure the binary got built, packaged, and installed, and at least
    # knows its own name
    firezone-client-gui --help | grep "Usage: firezone-client-gui"

    # Make sure the IPC service is running
    systemctl status "$SERVICE_NAME" || debug_exit
fi
