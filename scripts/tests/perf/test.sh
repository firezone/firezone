#!/usr/bin/env bash

set -euox pipefail

mkdir -p iperf3results

# Establish a channel first. Helps the iperf3 test to be more stable.
docker compose exec -it client timeout 60 \
    sh -c 'until ping -W 1 -c 1 172.20.0.110 &>/dev/null; do true; done'

# Tests are limited to a bitrate of 100M. Otherwise iperf3 can become
# overloaded and exit with code 1. These are running on shared runners after all.
docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -b 100M -R -c 172.20.0.110 --json' >>iperf3results/tcp_server2client.json
docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -b 100M -c 172.20.0.110 --json' >>iperf3results/tcp_client2server.json
docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -u -b 100M -R -c 172.20.0.110 --json' >>iperf3results/udp_server2client.json
docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -u -b 100M -c 172.20.0.110 --json' >>iperf3results/udp_client2server.json
