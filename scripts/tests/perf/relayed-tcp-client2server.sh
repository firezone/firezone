#!/usr/bin/env bash

set -euox pipefail

source "./scripts/tests/lib.sh"

# Enforce IPv4 - IPv4 relaying
install_iptables_drop_rules ipv4 ipv4

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 \
  --time 30 \
  --client 172.20.0.110 \
  --json' >>"${TEST_NAME}.json"

assert_process_state "relay-1" "S"
assert_process_state "relay-2" "S"
assert_process_state "gateway" "S"
assert_process_state "client" "S"
