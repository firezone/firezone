#!/usr/bin/env bash

set -euo pipefail

mkdir -p iperf3results

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -t 30 -O 1 -R -c 172.20.0.110 --json' >>iperf3results/tcp_server2client.json

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -t 30 -O 1 -c 172.20.0.110 --json' >>iperf3results/tcp_client2server.json

# Note: bitrate is reduced to be 250M but what we actually want to test for is 1G once we flesh out some bugs
docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -t 30 -O 1 -u -b 250M -R -c 172.20.0.110 --json' >>iperf3results/udp_server2client.json

# Note: bitrate is reduced to be 250M but what we actually want to test for is 1G once we flesh out some bugs
docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -t 30 -O 1 -u -b 250M -c 172.20.0.110 --json' >>iperf3results/udp_client2server.json
