#!/bin/sh

if [ -f "${FIREZONE_TOKEN}" ]; then
    FIREZONE_TOKEN="$(cat "${FIREZONE_TOKEN}")"
    export FIREZONE_TOKEN
fi

exec "$@"
