#!/usr/bin/env bash
# Test Linux DNS control using `systemd-resolved` directly inside the CI runner

set -euo pipefail

BINARY_NAME=firezone-linux-client

docker compose exec client cat firezone-linux-client > "$BINARY_NAME"
chmod u+x "$BINARY_NAME"
sudo mv "$BINARY_NAME" "/usr/bin/$BINARY_NAME"
# TODO: Check whether this is redundant with the systemd service file
sudo setcap cap_net_admin+eip "/usr/bin/$BINARY_NAME"

sudo cp scripts/tests/systemd/firezone-client.service /etc/systemd/system/
systemd-analyze security firezone-client

HTTPBIN=test.httpbin.docker.local

# I'm assuming the docker iface name is relatively constant
DOCKER_IFACE="docker0"
FZ_IFACE="tun-firezone"

echo "# Accessing a resource should fail before the client is up"
# Force curl to try the Firezone interface. I can't block off the Docker interface yet
# because it may be needed for the client to reach the portal.
curl --interface "$FZ_IFACE" $HTTPBIN/get && exit 1

echo "# Start Firezone"
resolvectl dns tun-firezone && exit 1
if ! sudo systemctl start firezone-client
then
    sudo systemctl status firezone-client
    exit 1
fi
resolvectl dns tun-firezone
resolvectl query "$HTTPBIN"

echo "# Accessing a resource should succeed after the client is up"
# Block off Docker's DNS.
sudo resolvectl dns "$DOCKER_IFACE" ""
curl -v $HTTPBIN/get

echo "# Make sure it's going through the tunnel"
nslookup "$HTTPBIN" | grep "100\\.96\\.0\\."

echo "# Print some debug info"
resolvectl status
