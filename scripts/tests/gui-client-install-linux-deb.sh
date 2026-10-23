#!/usr/bin/env bash
#
# Runs from `rust/gui-client` or `rust/tauri-client`

set -euox pipefail

SERVICE_NAME=firezone

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

# Confirm the GUI, the daemon-and-CLI binary, its alias and at least one icon
# were installed, and that the package carries the daemon's unit.
which firezone-client-gui firezone firezone-client-tunnel
test -f /usr/lib/systemd/system/firezone.service
stat /usr/share/icons/hicolor/512x512/apps/firezone-client-gui.png

# Make sure the binaries got built, packaged, and installed, and at least
# know their own names. The CLI and the GUI are separate programs, so their
# help output must not be the same.
firezone-client-gui --help | grep "Usage: firezone-client-gui"
firezone --help | grep "Usage: firezone \["

# Make sure the daemon is running, under its new name and the old one.
systemctl status "$SERVICE_NAME" || debug_exit
systemctl status firezone-client-tunnel || debug_exit
