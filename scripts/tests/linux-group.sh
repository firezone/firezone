#!/usr/bin/env bash

# The integration tests call this to test security for Linux IPC.
# Only users in the `firezone` group should be able to control the privileged tunnel process.

set -euox pipefail

BINARY_NAME=firezone-linux-client
SERVICE_NAME=firezone-client

function systemctl_status() {
    systemctl status "$SERVICE_NAME"
}

trap systemctl_status EXIT

# Copy the Linux Client out of its container
docker compose exec client cat firezone-linux-client > "$BINARY_NAME"
chmod u+x "$BINARY_NAME"
sudo mv "$BINARY_NAME" "/usr/bin/$BINARY_NAME"

sudo cp "scripts/tests/systemd/$SERVICE_NAME.service" /usr/lib/systemd/system/
systemd-analyze security "$SERVICE_NAME"

sudo systemctl start "$SERVICE_NAME"

FZ_GROUP="firezone"

sudo groupadd "$FZ_GROUP"

# Make sure we don't belong to the group yet
(groups | grep "$FZ_GROUP") && exit 1

# TODO: Expect Firezone to reject our commands here before the group is created
"$BINARY_NAME" debug-ipc-client && exit 1

sudo gpasswd --add "$USER" "$FZ_GROUP"

# Start a new login shell to update our groups, and check again
sudo su --login "$USER" --command groups | grep "$FZ_GROUP"

# TODO: Expect Firezone to accept our commands if we run with `su --login`
sudo su --login "$USER" --command "$BINARY_NAME" debug-ipc-client

# TODO: Expect Firezone to reject our command if we run without `su --login`
"$BINARY_NAME" debug-ipc-client && exit 1

# Explicitly exiting is needed when we're intentionally having commands fail
exit 0
