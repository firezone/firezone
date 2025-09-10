#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

client sh -c "curl --fail --output download.file http://download.httpbin/bytes?num=10000000" &

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
