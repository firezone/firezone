#!/usr/bin/env bash

# The integration tests call this to test security for Linux IPC.
# Only users in the `firezone` group should be able to control the privileged tunnel process.

source "./scripts/tests/lib.sh"

BINARY_NAME=firezone-client-ipc
FZ_GROUP="firezone-client"
SERVICE_NAME=firezone-client-ipc
SOCKET=/run/dev.firezone.client/tunnel.sock
export RUST_LOG=info

cd rust || exit 1
cargo build --bin "$BINARY_NAME"
cd ..

function debug_exit() {
    systemctl status "$SERVICE_NAME"
    exit 1
}

# Copy the Linux Client out of the build dir
sudo cp "rust/target/debug/$BINARY_NAME" "/usr/bin/$BINARY_NAME"

# Set up the systemd service
sudo cp "rust/gui-client/src-tauri/deb_files/$SERVICE_NAME.service" /usr/lib/systemd/system/
sudo cp "scripts/tests/systemd/env" "/etc/default/firezone-client-ipc"

# The firezone group must exist before the daemon starts
sudo groupadd "$FZ_GROUP"
sudo systemctl start "$SERVICE_NAME" || debug_exit

# Make sure the socket has the right permissions
if [ "root $FZ_GROUP" != "$(stat -c '%U %G' $SOCKET)" ]
then
    exit 1
fi

# Stop the service in case other tests run on the same VM
sudo systemctl stop "$SERVICE_NAME"

# Explicitly exiting is needed when we're intentionally having commands fail
exit 0
