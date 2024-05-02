#!/usr/bin/env bash

# The integration tests call this to test security for Linux IPC.
# Only users in the `firezone` group should be able to control the privileged tunnel process.

source "./scripts/tests/lib.sh"

BINARY_NAME=firezone-client-ipc
FZ_GROUP="firezone-client"
SERVICE_NAME=firezone-client-ipc
SOCKET=/run/dev.firezone.client/ipc.sock
export RUST_LOG=info

# Copy the Linux Client out of the build dir
sudo cp "rust/target/debug/firezone-headless-client" "/usr/bin/$BINARY_NAME"

# Set up the systemd service
sudo cp "rust/gui-client/src-tauri/deb_files/$SERVICE_NAME.service" /usr/lib/systemd/system/
sudo cp "scripts/tests/systemd/env" "/etc/default/firezone-client-ipc"

# The firezone group must exist before the daemon starts
sudo groupadd "$FZ_GROUP"
sudo systemctl start "$SERVICE_NAME" || { systemctl status "$SERVICE_NAME"; exit 1; }

# Make sure the socket has the right permissions
if [ "root $FZ_GROUP" != "$(stat -c '%U %G' $SOCKET)" ]
then
    exit 1
fi

# Add ourselves to the firezone group
sudo gpasswd --add "$USER" "$FZ_GROUP"

echo "# Expect Firezone to accept our commands if we run with 'su --login'"
sudo su --login "$USER" --command RUST_LOG="$RUST_LOG" "$BINARY_NAME" stub-ipc-client

echo "# Expect Firezone to reject our command if we run without 'su --login'"
"$BINARY_NAME" stub-ipc-client && exit 1

# Stop the service in case other tests run on the same VM
sudo systemctl stop "$SERVICE_NAME"

# Explicitly exiting is needed when we're intentionally having commands fail
exit 0
