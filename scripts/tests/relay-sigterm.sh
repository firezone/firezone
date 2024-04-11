#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

# Arrange: Setup a relayed connection
install_iptables_drop_rules
client_curl_resource "172.20.0.100/get"

# Act: Send SIGTERM
sudo kill --signal SIGTERM "$(pgrep firezone-relay)"

# Assert: Process is still there and dataplane still works
pgrep firezone-relay
client_curl_resource "172.20.0.100/get"

OPEN_SOCKETS=$(sudo docker exec -it firezone-relay-1 ss --tcp --numeric state established dport 8081 | tail --lines=+2) # Portal listens on port 8081, list all open connections
test -z "$OPEN_SOCKETS" # Assert that there are none

# Act: Send 2nd SIGTERM
sudo kill --signal SIGTERM "$(pgrep firezone-relay)"

# Assert: Process is no longer there
pgrep firezone-relay && exit 1
