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

# Debug-print the files. The icons and both binaries should be in here
dpkg --listfiles firezone-client-gui
# Print the deps
dpkg --info "$DEB_PATH"

# Confirm that both binaries and at least one icon were installed
which firezone-client-gui firezone-client-tunnel
stat /usr/share/icons/hicolor/512x512/apps/firezone-client-gui.png

# Make sure the binary got built, packaged, and installed, and at least
# knows its own name
firezone-client-gui --help | grep "Usage: firezone-client-gui"

# Make sure the Tunnel service is running
systemctl status "$SERVICE_NAME" || debug_exit

# Verify the AppArmor profiles loaded and the tunnel is actually confined.
# The whole point of the profile is to refuse IPC connections from peers that
# aren't labeled `firezone-client-gui`; check that property end-to-end.
SOCKET=/run/dev.firezone.client/tunnel.sock

sudo aa-status
sudo aa-status | grep -q firezone-client-tunnel
sudo aa-status | grep -q firezone-client-gui
sudo aa-status --enforced | grep -q firezone-client-tunnel

# Positive: a process with the `firezone-client-gui` label is accepted.
sudo aa-exec -p firezone-client-gui -- python3 -c "
import socket
s = socket.socket(socket.AF_UNIX)
s.connect('$SOCKET')
s.close()
"

# Negative: an unconfined process is refused by the tunnel's AppArmor profile
# even though it runs as root (POSIX permissions would let it through).
if sudo python3 -c "
import socket
s = socket.socket(socket.AF_UNIX)
s.connect('$SOCKET')
s.close()
" 2>/dev/null
then
    echo "FAIL: unconfined process was allowed to connect to the IPC socket"
    exit 1
fi
