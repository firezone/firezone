#!/usr/bin/env bash

set -xe

cat /tmp/iperf3results-main/tcp_server2client.json | jq -r '"tcp_server2client_sum_received_bits_per_second=" + (.end.sum_received.bits_per_second|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results-main/tcp_server2client.json | jq -r '"tcp_server2client_sum_sent_bits_per_second=" + (.end.sum_sent.bits_per_second|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results-main/tcp_server2client.json | jq -r '"tcp_server2client_sum_sent_retransmits=" + (.end.sum_sent.retransmits|tostring)' >>"$GITHUB_OUTPUT"

cat /tmp/iperf3results-main/tcp_client2server.json | jq -r '"tcp_client2server_sum_received_bits_per_second=" + (.end.sum_received.bits_per_second|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results-main/tcp_client2server.json | jq -r '"tcp_client2server_sum_sent_bits_per_second=" + (.end.sum_sent.bits_per_second|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results-main/tcp_client2server.json | jq -r '"tcp_client2server_sum_sent_retransmits=" + (.end.sum_sent.retransmits|tostring)' >>"$GITHUB_OUTPUT"

cat /tmp/iperf3results-main/udp_server2client.json | jq -r '"udp_server2client_sum_bits_per_second=" + (.end.sum.bits_per_second|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results-main/udp_server2client.json | jq -r '"udp_server2client_sum_jitter_ms=" + (.end.sum.jitter_ms|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results-main/udp_server2client.json | jq -r '"udp_server2client_sum_lost_percent=" + (.end.sum.lost_percent|tostring)' >>"$GITHUB_OUTPUT"

cat /tmp/iperf3results-main/udp_client2server.json | jq -r '"udp_client2server_sum_bits_per_second=" + (.end.sum.bits_per_second|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results-main/udp_client2server.json | jq -r '"udp_client2server_sum_jitter_ms=" + (.end.sum.jitter_ms|tostring)' >>"$GITHUB_OUTPUT"
cat /tmp/iperf3results-main/udp_client2server.json | jq -r '"udp_client2server_sum_lost_percent=" + (.end.sum.lost_percent|tostring)' >>"$GITHUB_OUTPUT"
