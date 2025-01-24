#!/usr/bin/env bash
#
# Runs from `rust/gui-client` or `rust/tauri-client`

set -euox pipefail

SERVICE_NAME=firezone-client-ipc

function debug_exit() {
    systemctl status "$SERVICE_NAME"
    exit 1
}

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
