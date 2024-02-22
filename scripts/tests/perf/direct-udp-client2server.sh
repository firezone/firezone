#!/usr/bin/env bash

set -euox pipefail

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 \
  --udp \
  --bandwidth 1G \
  --client 172.20.0.110 \
  --json' >>"${TEST_NAME}.json"
