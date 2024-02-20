#!/usr/bin/env bash

set -euox pipefail

mkdir -p iperf3results

# Establish a channel first. Helps the iperf3 test to be more stable.
docker compose exec -it client timeout 60 \
    sh -c 'until ping -W 1 -c 1 172.20.0.110 &>/dev/null; do true; done'

# Restart the iperf3 server after each test. It can sometimes hang, which causes these to exit with code 1
# when the iperf3 server can't be reached.
docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -b 1G -R -c 172.20.0.110 --json' >>iperf3results/tcp_server2client.json
docker compose restart iperf3
docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -b 1G -c 172.20.0.110 --json' >>iperf3results/tcp_client2server.json
docker compose restart iperf3
docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -u -b 1G -R -c 172.20.0.110 --json' >>iperf3results/udp_server2client.json
docker compose restart iperf3
docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -u -b 1G -c 172.20.0.110 --json' >>iperf3results/udp_client2server.json
