#!/usr/bin/env bash

set -euox pipefail

source "./scripts/tests/lib.sh"
install_iptables_drop_rules

sudo iptables -L DOCKER-USER -n -v

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 \
  --client 172.20.0.110 \
  --json' >>"${TEST_NAME}.json"

assert_process_state "relay-1" "S"
assert_process_state "relay-2" "S"
assert_process_state "gateway" "S"
assert_process_state "client" "S"
