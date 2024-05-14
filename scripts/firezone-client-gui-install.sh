#!/usr/bin/env bash
# Usage: ./firezone-client-gui-install.sh ./firezone-client-gui_VERSION_ARCH.deb
#
# The `./` is necessary
#
# This script should be idempotent, so it can be used for upgrades, too.
set -euox pipefail

# `apt-get` needs either a leading `./` or `/` to recognize a local file path
DEB_PATH=$(realpath "$1")
GROUP_NAME="firezone-client"
SERVICE_NAME="firezone-client-ipc"

echo "Installing Firezone..."
sudo apt-get install --yes "$DEB_PATH"

echo "Adding your user to the $GROUP_NAME group..."
# Creates the system group `firezone-client`
sudo systemd-sysusers
sudo adduser "$USER" "$GROUP_NAME"

echo "Starting and enabling Firezone IPC service..."
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

# Check if the user is already in the group
if ! groups "$USER" | grep "$GROUP_NAME" &>/dev/null; then
    # Unfortunately Ubuntu seems to need a reboot here, at least 20.04 does
    echo "Reboot to finish adding yourself to the group"
fi
