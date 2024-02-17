#!/usr/bin/env bash

set -xe

mkdir -p /tmp/iperf3results
docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -t 30 -O 1 -R -c 172.20.0.110 --json' >>/tmp/iperf3results/tcp_server2client.json
cat /tmp/iperf3results/tcp_server2client.json | jq -r '"tcp_server2client_sum_received_bits_per_second=" + (.end.sum_received.bits_per_second|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results/tcp_server2client.json | jq -r '"tcp_server2client_sum_sent_bits_per_second=" + (.end.sum_sent.bits_per_second|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results/tcp_server2client.json | jq -r '"tcp_server2client_sum_sent_retransmits=" + (.end.sum_sent.retransmits|tostring)' >>"$GITHUB_OUTPUT"

docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -t 30 -O 1 -c 172.20.0.110 --json' >>/tmp/iperf3results/tcp_client2server.json
cat /tmp/iperf3results/tcp_client2server.json | jq -r '"tcp_client2server_sum_received_bits_per_second=" + (.end.sum_received.bits_per_second|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results/tcp_client2server.json | jq -r '"tcp_client2server_sum_sent_bits_per_second=" + (.end.sum_sent.bits_per_second|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results/tcp_client2server.json | jq -r '"tcp_client2server_sum_sent_retransmits=" + (.end.sum_sent.retransmits|tostring)' >>"$GITHUB_OUTPUT"

# Note: birtate is reduced to be 250M but what we actually want to test for is 1G once we flesh out some bugs
docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -t 30 -O 1 -u -b 250M -R -c 172.20.0.110 --json' >>/tmp/iperf3results/udp_server2client.json
cat /tmp/iperf3results/udp_server2client.json | jq -r '"udp_server2client_sum_bits_per_second=" + (.end.sum.bits_per_second|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results/udp_server2client.json | jq -r '"udp_server2client_sum_jitter_ms=" + (.end.sum.jitter_ms|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results/udp_server2client.json | jq -r '"udp_server2client_sum_lost_percent=" + (.end.sum.lost_percent|tostring)' >>"$GITHUB_OUTPUT"

# Note: birtate is reduced to be 250M but what we actually want to test for is 1G once we flesh out some bugs
docker compose exec --env RUST_LOG=info -it client /bin/sh -c 'iperf3 -t 30 -O 1 -u -b 250M -c 172.20.0.110 --json' >>/tmp/iperf3results/udp_client2server.json
cat /tmp/iperf3results/udp_client2server.json | jq -r '"udp_client2server_sum_bits_per_second=" + (.end.sum.bits_per_second|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results/udp_client2server.json | jq -r '"udp_client2server_sum_jitter_ms=" + (.end.sum.jitter_ms|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results/udp_client2server.json | jq -r '"udp_client2server_sum_lost_percent=" + (.end.sum.lost_percent|tostring)' >>"$GITHUB_OUTPUT"
