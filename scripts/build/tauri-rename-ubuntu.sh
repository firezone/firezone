#!/usr/bin/env bash
set -euox pipefail

# For debugging
ls ../target/release ../target/release/bundle/deb

# Used for release artifact
# In release mode the name comes from tauri.conf.json
# Using a glob for the source, there will only be one exe and one deb anyway
cp ../target/release/firezone-client-gui "$BINARY_DEST_PATH"-x86_64
cp ../target/release/firezone-gui-client.dwp "$BINARY_DEST_PATH"-x86_64.dwp
cp ../target/release/bundle/deb/*_amd64.deb "$BINARY_DEST_PATH"_x86_64.deb
# TODO: Debug symbols for Linux

function make_hash() {
    sha256sum "$1"> "$1.sha256sum.txt"
}

# I think we agreed in standup to just match platform conventions
# Firezone for Windows is "-x64" which I believe is Visual Studio's convention
# Debian calls it "amd64". Rust and Linux call it "x86_64". So whatever, it's
# amd64 here. They're all the same.
make_hash "$BINARY_DEST_PATH"-x86_64.dwp
make_hash "$BINARY_DEST_PATH"_x86_64.deb

# Test the deb package, since this script is the easiest place to get a release build
sudo dpkg --install "$BINARY_DEST_PATH"_x86_64.deb

# Debug-print the files. The icons and both binaries should be in here
dpkg --listfiles firezone-client-gui

# Confirm that both binaries and at least one icon were installed
which firezone-client-gui firezone-client-ipc
stat /usr/share/icons/hicolor/512x512/apps/firezone.png

# Make sure the binary got built, packaged, and installed, and at least
# knows its own name
firezone-client-gui --help | grep "Usage: firezone-client-gui"

# Try to start the IPC service
sudo systemctl start firezone-client-ipc || systemctl status firezone-client-ipc
