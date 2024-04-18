#!/usr/bin/env bash
# Test Linux DNS control using `systemd-resolved` directly inside the CI runner

source "./scripts/tests/lib.sh"

BINARY_NAME=firezone-headless-client
CONFIG_DIR=/etc/dev.firezone.client
SERVICE_NAME=firezone-client
TOKEN_PATH="$CONFIG_DIR/token.txt"

# Copy the Client out of its container
docker compose exec client cat firezone-headless-client > "$BINARY_NAME"
chmod u+x "$BINARY_NAME"
sudo chown root:root "$BINARY_NAME"
sudo mv "$BINARY_NAME" "/usr/bin/$BINARY_NAME"

create_token_file

sudo cp "scripts/tests/systemd/$SERVICE_NAME.service" /usr/lib/systemd/system/

HTTPBIN=dns.httpbin

# I'm assuming the docker iface name is relatively constant
DOCKER_IFACE="docker0"
FZ_IFACE="tun-firezone"

# Accessing a resource should fail before the client is up
# Force curl to try the Firezone interface. I can't block off the Docker interface yet
# because it may be needed for the client to reach the portal.
curl --interface "$FZ_IFACE" $HTTPBIN/get && exit 1

# Start Firezone
resolvectl dns tun-firezone && exit 1
stat /usr/bin/firezone-linux-client
sudo systemctl start "$SERVICE_NAME"
resolvectl dns tun-firezone
resolvectl query "$HTTPBIN"

# Accessing a resource should succeed after the client is up
# Block off Docker's DNS.
sudo resolvectl dns "$DOCKER_IFACE" ""
curl -v $HTTPBIN/get

# Make sure it's going through the tunnel
nslookup "$HTTPBIN" | grep "100\\.96\\.0\\."

# Print some debug info
resolvectl status
