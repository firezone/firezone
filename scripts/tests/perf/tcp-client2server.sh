#!/usr/bin/env bash

set -euox pipefail

source "./scripts/tests/lib.sh"

docker compose exec --env RUST_LOG=info -it client-1 /bin/sh -c 'iperf3 \
  --time 30 \
  --client 172.20.0.110 \
  --json' >>"${TEST_NAME}.json"

jq --arg name "${TEST_NAME}" \
    '{ ($name): { "retransmits": { "value": (.end.sum_sent.retransmits // -1) }, "throughput": { "value": .end.sum_received.bits_per_second } } }' \
    "${TEST_NAME}.json" >"${TEST_NAME}.bmf.json"

assert_process_state "gateway" "S"
assert_process_state "client-1" "S"
