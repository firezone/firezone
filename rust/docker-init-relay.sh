#!/bin/sh

if [ -f "${FIREZONE_TOKEN}" ]; then
    FIREZONE_TOKEN="$(cat "${FIREZONE_TOKEN}")"
    export FIREZONE_TOKEN
fi

if [ "${LISTEN_ADDRESS_DISCOVERY_METHOD}" = "gce_metadata" ]; then
    echo "Using GCE metadata to discover listen address"

    if [ "${PUBLIC_IP4_ADDR}" = "" ]; then
        public_ip4=$(curl "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" -H "Metadata-Flavor: Google" -s)
        export PUBLIC_IP4_ADDR="${public_ip4}"
        echo "Discovered PUBLIC_IP4_ADDR: ${PUBLIC_IP4_ADDR}"
    fi

    if [ "${PUBLIC_IP6_ADDR}" = "" ]; then
        public_ip6=$(curl "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ipv6s" -H "Metadata-Flavor: Google" -s)
        export PUBLIC_IP6_ADDR="${public_ip6}"
        echo "Discovered PUBLIC_IP6_ADDR: ${PUBLIC_IP6_ADDR}"
    fi
fi

if [ "${OTEL_METADATA_DISCOVERY_METHOD}" = "gce_metadata" ]; then
    echo "Using GCE metadata to set OTEL metadata"

    instance_id=$(curl "http://metadata.google.internal/computeMetadata/v1/instance/id" -H "Metadata-Flavor: Google" -s)
    export OTEL_RESOURCE_ATTRIBUTES="service.instance.id=${instance_id}"
    echo "Discovered OTEL metadata: ${OTEL_RESOURCE_ATTRIBUTES}"

fi

exec "$@"
