#!/usr/bin/env bash

set -euox pipefail

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 \
  --reverse \
  --omit 10 \
  --time 30 \
  --zerocopy \
  --set-mss 1240 \
  --client 172.20.0.110 \
  --json' >>"${TEST_NAME}.json"
