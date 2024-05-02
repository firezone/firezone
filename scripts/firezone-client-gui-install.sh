#!/usr/bin/env bash
# Usage: ./firezone-client-gui-install.sh ./firezone-client-gui_VERSION_ARCH.deb
#
# The `./` is necessary
#
# This script should be idempotent
set -euox pipefail

# `apt-get` needs either a leading `./` or `/` to recognize a local file path
DEB_PATH=$(realpath "$1")

echo "Installing Firezone..."
sudo apt-get install "$DEB_PATH"

echo "Adding your user to the firezone-client group..."
# Creates the system group `firezone-client`
sudo systemd-sysusers
sudo adduser "$USER" firezone-client

echo "Starting and enabling Firezone IPC service..."
sudo systemctl enable --now firezone-client-ipc

# Unfortunately Ubuntu seems to need a reboot here, at least 20.04 does
echo "Reboot to finish adding yourself to the group"
