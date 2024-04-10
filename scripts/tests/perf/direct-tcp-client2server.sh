#!/usr/bin/env bash

set -euox pipefail

source "./scripts/tests/lib.sh"

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 \
  --client 172.20.0.110 \
  --json' >>"${TEST_NAME}.json"

assert_process_state "firezone-gateway" "S"
assert_process_state "firezone-headless-client" "S"
