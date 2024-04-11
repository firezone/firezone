#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

# Arrange: Setup a relayed connection
install_iptables_drop_rules
client_curl_resource "172.20.0.100/get"

# Act: Send SIGTERM
sudo kill --signal HUP "$(pgrep firezone-relay)"

# Assert: Process is still there and dataplane still works
pgrep firezone-relay
client_curl_resource "172.20.0.100/get"
# TODO: Assert via API that relay disconnected the websocket.

# Act: Send 2nd SIGTERM
sudo kill --signal HUP "$(pgrep firezone-relay)"

# Assert: Process is no longer there
pgrep firezone-relay && exit 1
