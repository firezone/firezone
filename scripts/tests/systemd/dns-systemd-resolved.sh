#!/usr/bin/env bash
# Test Linux DNS control using `systemd-resolved` directly inside the CI runner

set -euox pipefail

BINARY_NAME=firezone-linux-client
CONFIG_DIR=/etc/dev.firezone.client
SERVICE_NAME=firezone-client
TOKEN_PATH="$CONFIG_DIR/token.txt"

function systemctl_status {
    systemctl status "$SERVICE_NAME"
}
trap systemctl_status EXIT

docker compose exec client cat firezone-linux-client > "$BINARY_NAME"
chmod u+x "$BINARY_NAME"
sudo chown root:root "$BINARY_NAME"
sudo mv "$BINARY_NAME" "/usr/bin/$BINARY_NAME"
# TODO: Check whether this is redundant with the systemd service file
sudo setcap cap_net_admin+eip "/usr/bin/$BINARY_NAME"

sudo mkdir "$CONFIG_DIR"
sudo touch "$TOKEN_PATH"
sudo chmod 600 "$TOKEN_PATH"
echo "n.SFMyNTY.g2gDaANtAAAAJGM4OWJjYzhjLTkzOTItNGRhZS1hNDBkLTg4OGFlZjZkMjhlMG0AAAAkN2RhN2QxY2QtMTExYy00NGE3LWI1YWMtNDAyN2I5ZDIzMGU1bQAAACtBaUl5XzZwQmstV0xlUkFQenprQ0ZYTnFJWktXQnMyRGR3XzJ2Z0lRdkZnbgYAGUmu74wBYgABUYA.UN3vSLLcAMkHeEh5VHumPOutkuue8JA6wlxM9JxJEPE" | sudo tee "$TOKEN_PATH" > /dev/null

sudo cp "scripts/tests/systemd/$SERVICE_NAME.service" /usr/lib/systemd/system/
systemd-analyze security "$SERVICE_NAME"

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
