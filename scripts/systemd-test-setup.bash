#!/usr/bin/env bash

set -euo pipefail

BINARY_NAME=firezone-linux-client

docker compose exec client cat firezone-linux-client > "$BINARY_NAME"
chmod u+x "$BINARY_NAME"
sudo mv "$BINARY_NAME" "/usr/bin/$BINARY_NAME"
# TODO: Check whether this is redundant with the systemd service file
sudo setcap cap_net_admin+eip "/usr/bin/$BINARY_NAME"

sudo cp scripts/firezone-client.service /etc/systemd/system/
systemd-analyze security firezone-client
