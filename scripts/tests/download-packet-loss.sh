#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

client apk add --no-cache --update iproute2
client tc qdisc add dev eth0 root netem loss 20%

# Abort only if the transfer stalls, never on a fixed deadline: 20% loss makes
# the download legitimately slow and bursty. Deliberately no --connect-timeout:
# under 20% loss the tunnel handshake and TCP connect can take well over ten
# seconds, so a fixed connect deadline flakes (TCP's own retransmit limit still
# caps a truly-dead tunnel). The stall window is lenient (speed stays below 10
# KiB/s for 30s) so deep TCP retransmit backoff isn't mistaken for a hang.
client sh -c "curl --fail --speed-limit 10240 --speed-time 30 --output download.file http://download.httpbin/bytes?num=10000000" &

DOWNLOAD_PID=$!

wait $DOWNLOAD_PID || {
    echo "Download process failed"
    exit 1
}

known_checksum="f5e02aa71e67f41d79023a128ca35bad86cf7b6656967bfe0884b3a3c4325eaf"
computed_checksum=$(client sha256sum download.file | awk '{ print $1 }')

if [[ "$computed_checksum" != "$known_checksum" ]]; then
    echo "Checksum of downloaded file does not match"
    exit 1
fi
