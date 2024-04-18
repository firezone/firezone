#!/usr/bin/env bash

# The integration tests call this to test security for Linux IPC.
# Only users in the `firezone` group should be able to control the privileged tunnel process.

source "./scripts/tests/lib.sh"

BINARY_NAME=firezone-linux-client
FZ_GROUP="firezone"
SERVICE_NAME=firezone-client
SERVICE_FILE="scripts/tests/systemd/$SERVICE_NAME.service"
export RUST_LOG=info

function print_debug_info {
    systemctl status "$SERVICE_NAME"
}

trap print_debug_info EXIT

# Copy the Linux Client out of its container
docker compose exec client cat firezone-linux-client > "$BINARY_NAME"
chmod u+x "$BINARY_NAME"
sudo mv "$BINARY_NAME" "/usr/bin/$BINARY_NAME"

sudo cp "$SERVICE_FILE" /usr/lib/systemd/system/
cat "$SERVICE_FILE"

# The firezone group must exist before the daemon starts
sudo groupadd "$FZ_GROUP"
sudo systemctl start "$SERVICE_NAME"

# Add ourselves to the firezone group
sudo gpasswd --add "$USER" "$FZ_GROUP"

echo "# Expect Firezone to accept our commands if we run with 'su --login'"
sudo su --login "$USER" --command RUST_LOG="$RUST_LOG" "$BINARY_NAME" stub-ipc-client

echo "# Expect Firezone to reject our command if we run without 'su --login'"
"$BINARY_NAME" stub-ipc-client && exit 1

# Explicitly exiting is needed when we're intentionally having commands fail
exit 0
