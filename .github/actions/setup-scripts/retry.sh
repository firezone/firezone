#!/usr/bin/env bash
set -euo pipefail

max_attempts="${RETRY_MAX_ATTEMPTS:-5}"
delay="${RETRY_DELAY:-5}"
attempt=1

while true; do
    if "$@"; then
        exit 0
    fi
    if [[ $attempt -ge $max_attempts ]]; then
        echo "Command failed after $max_attempts attempts: $*" >&2
        exit 1
    fi
    echo "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..." >&2
    sleep $delay
    attempt=$((attempt + 1))
done
