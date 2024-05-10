#!/usr/bin/env bash
set -euox pipefail

FZ_GROUP="firezone-client"
SERVICE_NAME=firezone-client-ipc

function debug_exit() {
    systemctl status "$SERVICE_NAME"
    exit 1
}

# For debugging
ls ../target/release ../target/release/bundle/deb

# Used for release artifact
# In release mode the name comes from tauri.conf.json
# Using a glob for the source, there will only be one exe and one deb anyway
cp ../target/release/firezone-client-gui "$BINARY_DEST_PATH"
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
DEB_PATH=$(realpath "$BINARY_DEST_PATH.deb")
sudo apt-get install "$DEB_PATH"
# Update users / groups
sudo systemd-sysusers

# Debug-print the files. The icons and both binaries should be in here
dpkg --listfiles firezone-client-gui

# Confirm that both binaries and at least one icon were installed
which firezone-client-gui firezone-client-ipc
stat /usr/share/icons/hicolor/512x512/apps/firezone-client-gui.png

# Make sure the binary got built, packaged, and installed, and at least
# knows its own name
firezone-client-gui --help | grep "Usage: firezone-client-gui"

# Try to start the IPC service
sudo groupadd --force "$FZ_GROUP"
sudo systemctl start "$SERVICE_NAME" || debug_exit
