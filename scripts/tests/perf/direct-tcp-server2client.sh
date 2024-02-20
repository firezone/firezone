#!/usr/bin/env bash

set -euox pipefail

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 \
  # Run the test in reverse, server to client
  --reverse \
  # Our interface MTU is 1280, so we set the MSS to 1240 to avoid fragmentation
  --set-mss 1240 \
  # Send data using zero-copy writes for less CPU overhead
  --zerocopy \
  # Run in client mode
  --client 172.20.0.110 \
  --json' >>"${TEST_NAME}.json"
