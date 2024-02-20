#!/usr/bin/env bash

set -euox pipefail

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 \
  # Run in reverse mode, server to client
  --reverse \
  # Send data using zero-copy writes for less CPU overhead
  --zerocopy \
  # UDP test
  --udp \
  # Set the bandwidth to 1Gbps
  --bandwidth 1G  \
  # Run in client mode
  --client 172.20.0.110 \
  --json' >>"${TEST_NAME}.json"
