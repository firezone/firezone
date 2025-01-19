#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

# Arrange: Setup a relayed connection
install_iptables_drop_rules

# Arrange: Wait for one allocation refresh cycle
sleep 315

# Assert: Dataplane still works
client_curl_resource "172.20.0.100/get"
