#!/usr/bin/env bash

set -euox pipefail

source "./scripts/tests/perf/force-relayed.sh"

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -O 5 -t 30 -M 1240 -Z -R -c 172.20.0.110 --json' >>"${TEST_NAME}.json"
