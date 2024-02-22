#!/usr/bin/env bash

set -euox pipefail

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 \
  --set-mss 1240 \
  --omit 10 \
  --time 30 \
  --zerocopy \
  --client 172.20.0.110 \
  --json' >>"${TEST_NAME}.json"
