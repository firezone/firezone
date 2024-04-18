#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

# Arrange: Setup a relayed connection
install_iptables_drop_rules
client_curl_resource "172.20.0.100/get"

# Act: Send SIGTERM
docker compose kill relay-1 --signal SIGTERM

sleep 2 # Closing websocket isn't instant.

# Assert: Dataplane still works
client_curl_resource "172.20.0.100/get"

# Assert: Websocket connection is cut
OPEN_SOCKETS=$(relay1 netstat -tn | grep "ESTABLISHED" | grep 8081 || true) # Portal listens on port 8081
test -z "$OPEN_SOCKETS"

# Act: Send 2nd SIGTERM
docker compose kill relay-1 --signal SIGTERM

sleep 1 # Wait for process to exit

# Assert: Relay-1 is no longer there
if docker compose ps relay-1 >/dev/null; then
    echo "Relay-1 is still running."
    exit 1
fi
