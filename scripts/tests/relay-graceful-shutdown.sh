#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

# Arrange: Setup a relayed connection
force_relayed_connections
client_curl_resource "172.20.0.100/get"
client_curl_resource "[172:20:0::100]/get"

# Act: Send SIGTERM
docker compose kill relay-1 --signal SIGTERM

sleep 2 # Closing websocket isn't instant.

# Assert: Dataplane still works
client_curl_resource "172.20.0.100/get"
client_curl_resource "[172:20:0::100]/get"

# Assert: Websocket connection is cut
OPEN_SOCKETS=$(relay1 netstat -tn | grep "ESTABLISHED" | grep 8081 || true) # Portal listens on port 8081
test -z "$OPEN_SOCKETS"

# Act: Send 2nd SIGTERM
docker compose kill relay-1 --signal SIGTERM

sleep 5 # Wait for container to be fully exited

# Seems to be necessary to return the correct state
docker compose ps relay-1 --all
sleep 1

# Assert: Container exited
container_state=$(docker compose ps relay-1 --all --format json | jq --raw-output '.State')
assert_equals "$container_state" "exited"
