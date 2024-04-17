#!/usr/bin/env bash

# The integration tests call this to test security for Linux IPC.
# Only users in the `firezone` group should be able to control the privileged tunnel process.

set -euo pipefail

FZ_GROUP="firezone"

sudo groupadd "$FZ_GROUP"

# Make sure we don't belong to the group yet
(groups | grep "$FZ_GROUP") && exit 1

# TODO: Expect Firezone to reject our commands here

sudo gpasswd --add "$USER" "$FZ_GROUP"

# Start a new login shell to update our groups, and check again
sudo su --login "$USER" --command groups | grep "$FZ_GROUP"

# TODO: Expect Firezone to accept our commands if we run with `su --login`
