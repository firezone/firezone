#!/usr/bin/env bash

set -euox pipefail

source "./scripts/tests/lib.sh"
install_iptables_drop_rules

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 \
  --udp \
  --udp-counters-64bit \
  --omit 10 \
  --time 30 \
  --zerocopy \
  --bandwidth 1G \
  --client 172.20.0.110 \
  --json' >>"${TEST_NAME}.json"
