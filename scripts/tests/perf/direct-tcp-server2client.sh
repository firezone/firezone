#!/usr/bin/env bash

set -euox pipefail

source "./scripts/tests/perf/setup.sh"

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -t 30 -l 8K -M 1240 -Z -b 1M -R -c 172.20.0.110 --json' >>"${TEST_NAME}.json"
