#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

# Arrange: Setup a relayed connection
install_iptables_drop_rules
client_curl_resource "172.20.0.100/get"

# Act: Send SIGTERM
sudo kill --signal SIGTERM "$(pgrep firezone-relay)"

sleep 2 # Closing websocket isn't instant.

# Assert: Dataplane still works
client_curl_resource "172.20.0.100/get"

# Assert: Websocket connection is cut
OPEN_SOCKETS=$(relay netstat -tn | grep "ESTABLISHED" | grep 8081) # Portal listens on port 8081
test -z "$OPEN_SOCKETS"

# Act: Send 2nd SIGTERM
sudo kill --signal SIGTERM "$(pgrep firezone-relay)"

sleep 1 # Wait for process to exit

# Assert: Process is no longer there
if pgrep firezone-relay >/dev/null; then
    echo "Process is still running."
    exit 1
fi
