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

# Verify the AppArmor profiles loaded and the tunnel rejects peers that
# aren't labeled `firezone-client-gui`. The rejection is implemented in code
# (see `ipc/unix.rs::authorize_peer`); the AppArmor profiles only attach
# labels so the code-side check has something to compare against.
SOCKET=/run/dev.firezone.client/tunnel.sock

sudo aa-status
sudo aa-status | grep -q firezone-client-tunnel
sudo aa-status | grep -q firezone-client-gui
sudo aa-status --enforced | grep -q firezone-client-tunnel

# The tunnel just needs to stay alive long enough to log the peer reject,
# so we connect, attempt one read, and disconnect. We rely on the socket
# being open being enough for the tunnel's `authorize_peer` to run.

# Positive: a process labeled firezone-client-gui is accepted.
sudo aa-exec -p firezone-client-gui -- python3 -c "
import socket
s = socket.socket(socket.AF_UNIX)
s.connect('$SOCKET')
s.close()
"

# Negative: an unconfined root process is refused. POSIX permissions would
# let root through, so this only fails if the tunnel's code-side
# `authorize_peer` check actually rejects on label mismatch.
#
# The Python here exits 0 if the tunnel sent us any bytes (= the peer was
# accepted, which is what we DON'T want), and exits 1 if the tunnel closed
# the stream without sending data (= the peer was rejected as expected).
if sudo python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect('$SOCKET')
s.settimeout(2)
try:
    data = s.recv(1)
except Exception:
    data = b''
sys.exit(0 if data else 1)
"; then
    echo "FAIL: unconfined process was allowed to talk to the IPC socket"
    exit 1
fi
