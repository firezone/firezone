#!/usr/bin/env bash

set -euox pipefail

source "./scripts/tests/lib.sh"
install_iptables_drop_rules

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 \
  --reverse \
  --udp \
  --bandwidth 1G \
  --client 172.20.0.110 \
  --json' >>"${TEST_NAME}.json"
