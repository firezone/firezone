#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

# Arrange: Setup a relayed connection
install_iptables_drop_rules
client_curl_resource "172.20.0.100/get"

# Act: Send SIGTERM
relay kill --signal SIGTERM "$(pgrep firezone-relay)"

sleep 2 # Closing websocket isn't instant.

# Assert: Dataplane still works
client_curl_resource "172.20.0.100/get"

# Assert: Websocket connection is cut
OPEN_SOCKETS=$(relay ss --tcp --numeric state established dport 8081 | tail --lines=+2) # Portal listens on port 8081
test -z "$OPEN_SOCKETS"

# Act: Send 2nd SIGTERM
relay kill --signal SIGTERM "$(pgrep firezone-relay)"

# Assert: Process is no longer there
pgrep firezone-relay && exit 1
