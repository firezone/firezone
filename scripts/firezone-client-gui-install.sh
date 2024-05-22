#!/usr/bin/env bash
# Keep this synchronized with the Linux GUI docs in `/website/src/app/kb/user-guides/linux-gui-client`
# Usage: ./firezone-client-gui-install.sh ./firezone-client-gui_VERSION_ARCH.deb
#
# The `./` is necessary
#
# This script should be idempotent, so it can be used for upgrades, too.
set -euox pipefail

# `apt-get` needs either a leading `./` or `/` to recognize a local file path
DEB_PATH=$(realpath "$1")
GROUP_NAME="firezone-client"

echo "Installing Firezone..."
sudo apt-get install --yes "$DEB_PATH"

echo "Adding your user to the $GROUP_NAME group..."
sudo usermod -aG "$GROUP_NAME" "$USER"

# Check if the user is already in the group
if ! groups | grep "$GROUP_NAME" &>/dev/null; then
    # Unfortunately Ubuntu seems to need a reboot here, at least 20.04 does
    echo "You MUST reboot to finish adding yourself to the group. Firezone won't function correctly until this is done."
else
    echo "Finished installing / upgrading Firezone Client."
fi
