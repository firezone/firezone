#!/usr/bin/env bash
# Test Linux DNS control using `systemd-resolved` directly inside the CI runner
# This needs Docker Compose so we can run httpbin.

source "./scripts/tests/lib.sh"

BINARY_NAME=firezone-headless-client
SERVICE_NAME=firezone-client-headless

debug_exit() {
    echo "Bailing out. Waiting a couple seconds for things to settle..."
    sleep 5
    docker compose ps -a
    resolvectl dns tun-firezone || true
    systemctl status "$SERVICE_NAME" || true
    journalctl -eu "$SERVICE_NAME" || true
    exit 1
}

# Copy the Linux Client out of its container
docker compose cp client:/bin/"$BINARY_NAME" "$BINARY_NAME"
chmod u+x "$BINARY_NAME"
sudo chown root:root "$BINARY_NAME"
sudo mv "$BINARY_NAME" "/usr/bin/$BINARY_NAME"

create_token_file

sudo cp "scripts/tests/systemd/$SERVICE_NAME.service" /usr/lib/systemd/system/

HTTPBIN=dns
HTTPBIN_FQDN="$HTTPBIN.httpbin.search.test"

# I'm assuming the docker iface name is relatively constant
DOCKER_IFACE="docker0"
FZ_IFACE="tun-firezone"

echo "# Make sure gateway can reach httpbin by DNS"
gateway sh -c "curl --fail $HTTPBIN_FQDN/get"

echo "# Accessing a resource should fail before the client is up"
# Force curl to try the Firezone interface. I can't block off the Docker interface yet
# because it may be needed for the client to reach the portal.
curl --interface "$FZ_IFACE" $HTTPBIN/get && exit 1

echo "# Start Firezone"
resolvectl dns tun-firezone && exit 1
stat "/usr/bin/$BINARY_NAME"
sudo systemctl start "$SERVICE_NAME" || debug_exit

resolvectl dns tun-firezone
resolvectl query "$HTTPBIN" || debug_exit

# Accessing a resource should succeed after the client is up
# Block off Docker's DNS.
sudo resolvectl dns "$DOCKER_IFACE" ""
curl -v $HTTPBIN/get || debug_exit

# Make sure it's going through the tunnel
nslookup "$HTTPBIN" | grep "19\\.0\\.0\\."

# Print some debug info
resolvectl status
