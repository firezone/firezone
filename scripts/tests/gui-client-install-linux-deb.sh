#!/usr/bin/env bash
#
# Runs from `rust/gui-client` or `rust/tauri-client`

set -euox pipefail

SERVICE_NAME=firezone-client-tunnel

function debug_exit() {
    systemctl status "$SERVICE_NAME"
    exit 1
}

# Test the deb package, since this script is the easiest place to get a release build
DEB_PATH=$(realpath "$BINARY_DEST_PATH.deb")
sudo apt-get install "$DEB_PATH"

# Debug-print the files. The icons and all three binaries should be in here
dpkg --listfiles firezone-client-gui
# Print the deps
dpkg --info "$DEB_PATH"

# Confirm that all three binaries and at least one icon were installed
which firezone-client-gui firezone-client-tunnel firezone
stat /usr/share/icons/hicolor/512x512/apps/firezone-client-gui.png

# Make sure the binaries got built, packaged, and installed, and at least
# know their own names. The CLI and the GUI are separate programs, so their
# help output must not be the same.
firezone-client-gui --help | grep "Usage: firezone-client-gui"
firezone --help | grep "Usage: firezone \["

# Make sure the Tunnel service is running
systemctl status "$SERVICE_NAME" || debug_exit
