#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

# Arrange: Setup a relayed connection
install_iptables_drop_rules
client_curl_resource "172.20.0.100/get"

# Act: Send SIGTERM (our process is pid 1 in the container)
relay1 kill -s SIGTERM 1

sleep 2 # Closing websocket isn't instant.

# Assert: Dataplane still works
client_curl_resource "172.20.0.100/get"

# Assert: Websocket connection is cut
OPEN_SOCKETS=$(relay1 netstat -tn | grep "ESTABLISHED" | grep 8081 || true) # Portal listens on port 8081
test -z "$OPEN_SOCKETS"

# Act: Send 2nd SIGTERM
relay1 kill -s SIGTERM 1

sleep 1 # Wait for process to exit

# Assert: Process is no longer there
if pgrep firezone-relay >/dev/null; then
    echo "Process is still running."
    exit 1
fi
