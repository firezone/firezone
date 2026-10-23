#!/usr/bin/env bash

# The integration tests call this to test security for Linux IPC.
# Only users in the `firezone` group should be able to control the privileged tunnel process.

source "./scripts/tests/lib.sh"

BINARY_NAME=firezone
FZ_USER="firezone"
FZ_GROUP="firezone-client"
SERVICE_NAME=firezone
SOCKET=/run/dev.firezone.client/tunnel.sock
export RUST_LOG=info

cd rust || exit 1
cargo build -p firezone-headless-client --bin "$BINARY_NAME"
cd ..

function debug_exit() {
    systemctl status "$SERVICE_NAME"
    exit 1
}

# Copy the Linux Client out of the build dir
sudo cp "rust/target/debug/$BINARY_NAME" "/usr/bin/$BINARY_NAME"

# Set up the systemd service the way the packages do
sudo cp "rust/headless-client/debian/$SERVICE_NAME.service" /usr/lib/systemd/system/
sudo cp "scripts/tests/systemd/env" "/etc/default/firezone-client-tunnel"

# The daemon's user and the group that may control it must exist before it
# starts, and the unit loads the (empty) Gateway token file as a credential.
sudo systemd-sysusers "rust/headless-client/debian/$SERVICE_NAME.sysusers"
sudo systemd-tmpfiles --create "rust/headless-client/debian/$SERVICE_NAME.tmpfiles"
sudo systemctl start "$SERVICE_NAME" || debug_exit

# Make sure the socket has the right permissions
if [ "$FZ_USER $FZ_GROUP" != "$(stat -c '%U %G' $SOCKET)" ]
then
    exit 1
fi

# Stop the service in case other tests run on the same VM
sudo systemctl stop "$SERVICE_NAME"

# Explicitly exiting is needed when we're intentionally having commands fail
exit 0
