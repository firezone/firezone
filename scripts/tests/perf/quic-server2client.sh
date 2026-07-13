#!/usr/bin/env bash

set -euox pipefail

source "./scripts/tests/lib.sh"

docker compose run --rm -T secnetperf-client secnetperf \
    -target:172.20.0.111 \
    -exec:maxtput \
    -down:30s \
    -ptput:1 |
    tee "${TEST_NAME}.txt"

kbps=$(grep -oP 'Result: Download \K[0-9]+(?= kbps)' "${TEST_NAME}.txt")

jq --null-input --arg name "${TEST_NAME}" --argjson bps "$((kbps * 1000))" \
    '{ ($name): { "throughput": { "value": $bps } } }' >"${TEST_NAME}.bmf.json"

assert_process_state "gateway" "S"
assert_process_state "client-1" "S"
