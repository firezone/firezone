#!/usr/bin/env bash
# Test Linux DNS control using `systemd-resolved` directly inside the CI runner

set -euo pipefail

BINARY_NAME=firezone-linux-client

docker compose exec client cat firezone-linux-client > "$BINARY_NAME"
chmod u+x "$BINARY_NAME"
sudo mv "$BINARY_NAME" "/usr/bin/$BINARY_NAME"
# TODO: Check whether this is redundant with the systemd service file
sudo setcap cap_net_admin+eip "/usr/bin/$BINARY_NAME"

sudo cp scripts/firezone-client.service /etc/systemd/system/
systemd-analyze security firezone-client

HTTPBIN=test.httpbin.docker.local

IFACE_NAME="tun-firezone"

echo "# Accessing a resource should fail before the client is up"
# TODO: For now I'm cheating and forcing curl to try the tunnel iface.
# This doesn't test that Firezone is adding the routes.
# If I don't do this, curl just connects through the Docker bridge.
curl --interface "$IFACE_NAME" $HTTPBIN/get && exit 1

echo "# Start Firezone"
resolvectl dns tun-firezone && exit 1
if ! sudo systemctl start firezone-client
then
    sudo systemctl status firezone-client
    exit 1
fi
resolvectl dns tun-firezone

echo "# Accessing a resource should succeed after the client is up"
curl --interface "$IFACE_NAME" $HTTPBIN/get
