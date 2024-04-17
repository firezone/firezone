#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

# Arrange: Setup a relayed connection
install_iptables_drop_rules
client_curl_resource "172.20.0.100/get"

# Act: Send SIGTERM
docker compose kill relay --signal SIGTERM

sleep 2 # Closing websocket isn't instant.

# Assert: Dataplane still works
client_curl_resource "172.20.0.100/get"

# Assert: Websocket connection is cut
OPEN_SOCKETS=$(relay netstat -tn | grep "ESTABLISHED" | grep 8081 || true) # Portal listens on port 8081
test -z "$OPEN_SOCKETS"

# Act: Send 2nd SIGTERM
docker compose kill relay --signal SIGTERM

sleep 1 # Wait for container to be fully exited

# Assert: Container exited
container_state=$(docker compose ps relay --all --format json | jq --raw-output '.State')
assert_equals "$container_state" "exited"
