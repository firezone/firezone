#!/usr/bin/env bash

set -euox pipefail

# Establish a channel first. Helps the iperf3 test to be more stable.
docker compose exec -it client timeout 60 \
    sh -c 'until ping -W 1 -c 1 172.20.0.110 &>/dev/null; do true; done'
