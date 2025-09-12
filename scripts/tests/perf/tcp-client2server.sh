#!/usr/bin/env bash

set -euox pipefail

source "./scripts/tests/lib.sh"

client ping -c 1 172.20.0.110 # Prime connection to GW

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 \
  --time 30 \
  --client 172.20.0.110 \
  --json' >>"${TEST_NAME}.json"

assert_process_state "gateway" "S"
assert_process_state "client" "S"
