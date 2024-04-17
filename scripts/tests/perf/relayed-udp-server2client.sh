#!/usr/bin/env bash

set -euox pipefail

source "./scripts/tests/lib.sh"
install_iptables_drop_rules

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 \
  --reverse \
  --udp \
  --bandwidth 50M \
  --client 172.20.0.110 \
  --json' >>"${TEST_NAME}.json"

assert_process_state "relay-1" "firezone-relay" "S"
assert_process_state "relay-2" "firezone-relay" "S"
assert_process_state "gateway" "firezone-gateway" "S"
assert_process_state "client" "firezone-linux-client" "S"
