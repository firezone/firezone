#!/usr/bin/env bash

set -euox pipefail

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -Z -u -b 1G -R -c 172.20.0.110 --json' >>"${TEST_NAME}.json"
