#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

# Download 10MB at a max rate of 1MB/s. Shouldn't take longer than 20 seconds (allows for 10s of restablishing)
docker compose exec -it client sh -c \
    "curl \
        --fail \
        --max-time 20 \
        --limit-rate 1M http://download.httpbin/bytes?num=10000000" > download.file &

DOWNLOAD_PID=$!

sleep 3 # Download a bit

docker network disconnect firezone_app firezone-client-1 # Disconnect the client
sleep 1

docker network connect firezone_app firezone-client-1 --ip 172.28.0.200 # Reconnect client with a different IP
kill -s HUP $(ps -C firezone-linux-client -o pid=) # Send SIGHUP, triggering `reconnect` internally

wait $DOWNLOAD_PID || {
    echo "Download process failed"
    exit 1
}

known_checksum="a993f8c574e0fea8c1cdcbcd9408d9e2e107ee6e4d120edcfa11decd53fa0cae"
computed_checksum=$(sha256sum download.file | awk '{ print $1 }')

if [[ "$computed_checksum" != "$known_checksum" ]]; then
    echo "Checksum of downloaded file does not match"
    exit 1
fi
