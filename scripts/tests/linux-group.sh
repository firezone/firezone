#!/usr/bin/env bash

# The integration tests call this to test security for Linux IPC.
# Only users in the `firezone` group should be able to control the privileged tunnel process.

set -euo pipefail

FZ_GROUP="firezone"

# Make sure we don't belong to the group yet
(groups | grep "$FZ_GROUP") && exit 1

# TODO: Remove, just for debugging
groups

sudo gpasswd "$USER" --add "$FZ_GROUP"

# Start a new login shell to update our groups, and check again
sudo su --login "$USER" groups | grep "$FZ_GROUP"

# TODO: Remove, just for debugging
sudo su --login "$USER" groups

# TODO: Remove, just for debugging
# Try it without sudo and see if that works at all
su --login "$USER" groups
