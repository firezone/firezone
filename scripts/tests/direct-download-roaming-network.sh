#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

# Download happens at 1KB/s so this will take ~15 seconds
download_bytes 10000 "download.file" &
DOWNLOAD_PID=$!

sleep 3 # Download a bit

docker network disconnect firezone_app firezone-client-1 # Disconnect the client
sleep 1

docker network connect firezone_app firezone-client-1 --ip 172.28.0.200 # Reconnect client with a different IP
kill -s HUP $(ps -C firezone-linux-client -o pid=) # Send SIGHUP, triggering reconnect of client

wait $DOWNLOAD_PID || {
    echo "Download process failed"
    exit 1
}

known_checksum="95b532cc4381affdff0d956e12520a04129ed49d37e154228368fe5621f0b9a2"
computed_checksum=$(sha256sum download.file | awk '{ print $1 }')

if [[ "$computed_checksum" != "$known_checksum" ]]; then
    echo "Checksum of downloaded file does not match"
    exit 1
fi
