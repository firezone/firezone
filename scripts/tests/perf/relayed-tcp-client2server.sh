#!/usr/bin/env bash

set -euox pipefail

source "./scripts/tests/perf/force-relayed.sh"
source "./scripts/tests/perf/setup.sh"

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -c 172.20.0.110 --json' >>"${TEST_NAME}.json"
