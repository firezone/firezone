#!/usr/bin/env bash
# Test Linux DNS control using `systemd-resolved` directly inside the CI runner

set -euo pipefail

# TODO: Use DNS and not IP
# HTTPBIN_DNS=172.21.0.100
HTTPBIN_IP=172.20.0.100

IFACE_NAME="tun-firezone"

echo "# Accessing a resource should fail before the client is up"
# TODO: For now I'm cheating and forcing curl to try the tunnel iface.
# This doesn't test that Firezone is adding the routes.
# If I don't do this, curl just connects through the Docker bridge.
curl --interface "$IFACE_NAME" $HTTPBIN_IP/get && exit 1

echo "# Start Firezone"
resolvectl status tun-firezone && exit 1
if ! sudo systemctl start firezone-client
then
    sudo systemctl status firezone-client
    exit 1
fi
resolvectl status tun-firezone

echo "# Accessing a resource should succeed after the client is up"
curl --interface "$IFACE_NAME" $HTTPBIN_IP/get
