#!/bin/sh

if [ -f "${FIREZONE_TOKEN}" ]; then
    FIREZONE_TOKEN="$(cat "${FIREZONE_TOKEN}")"
    export FIREZONE_TOKEN
fi

# A gateway has no DNS to control; the daemon reads its resolvers from `resolv.conf`.
export FIREZONE_DNS_CONTROL=${FIREZONE_DNS_CONTROL:-"disabled"}

# Forwarding and masquerade rules are set up by the daemon once it serves a resource.

exec "$@"
