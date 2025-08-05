#!/bin/bash

# Install `iptables` to have it available in the compatibility tests
docker compose exec -it client /bin/sh -c 'apk add iptables'

# Execute within the client container because doing so from the host is not reliable in CI.
docker compose exec -it client /bin/sh -c 'iptables -A OUTPUT -d 172.28.0.245 -j DROP'

docker compose exec -T client sh -c \
  "curl \
        --fail \
        --max-time 13 \
        --keepalive-time 1 \
        --limit-rate 1000000 \
        --output download.file \
        http://download.httpbin/bytes?num=10000000" &

DOWNLOAD_PID=$!

wait $DOWNLOAD_PID || {
  echo "Download process failed"
  exit 1
}

known_checksum="f5e02aa71e67f41d79023a128ca35bad86cf7b6656967bfe0884b3a3c4325eaf"
computed_checksum=$(docker compose client sha256sum download.file | awk '{ print $1 }')

if [[ "$computed_checksum" != "$known_checksum" ]]; then
  echo "Checksum of downloaded file does not match"
  exit 1
fi
