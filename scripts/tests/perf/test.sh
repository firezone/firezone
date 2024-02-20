#!/usr/bin/env bash

set -euox pipefail

mkdir -p iperf3results

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -t 30 -b 250M -R -c 172.20.0.110 --json' >>iperf3results/tcp_server2client.json

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -t 30 -b 250M -c 172.20.0.110 --json' >>iperf3results/tcp_client2server.json

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -t 30 -u -b 250M -R -c 172.20.0.110 --json' >>iperf3results/udp_server2client.json

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -t 30 -u -b 250M -c 172.20.0.110 --json' >>iperf3results/udp_client2server.json
