#!/usr/bin/env bash

# The integration tests call this to test security for Linux IPC.
# Only users in the `firezone` group should be able to control the privileged tunnel process.

source "./scripts/tests/lib.sh"

BINARY_NAME=firezone-linux-client
FZ_GROUP="firezone"
SERVICE_NAME=firezone-client
export RUST_LOG=info

# Copy the Linux Client out of the build dir
ls . ./rust ./rust/target ./rust/target/debug
sudo cp "rust/target/debug/firezone-headless-client" "/usr/bin/$BINARY_NAME"

sudo cp "scripts/tests/systemd/$SERVICE_NAME.service" /usr/lib/systemd/system/

# The firezone group must exist before the daemon starts
sudo groupadd "$FZ_GROUP"
sudo systemctl start "$SERVICE_NAME"

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
