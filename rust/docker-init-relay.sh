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
elif [ "${LISTEN_ADDRESS_DISCOVERY_METHOD}" = "aws_ec2_metadata" ]; then
    echo "Using AWS EC2 metadata to discover listen address"
    token=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")

    if [ "${PUBLIC_IP4_ADDR}" = "" ]; then
        public_ip4=$(curl --fail "http://169.254.169.254/latest/meta-data/public-ipv4" -H "X-aws-ec2-metadata-token: $token")
        if [ $? -eq 0 ]; then
            export PUBLIC_IP4_ADDR="${public_ip4}"
            echo "Discovered PUBLIC_IP4_ADDR: ${PUBLIC_IP4_ADDR}"
        fi
    fi

    if [ "${PUBLIC_IP6_ADDR}" = "" ]; then
        public_ip6=$(curl --fail "http://169.254.169.254/latest/meta-data/ipv6" -H "X-aws-ec2-metadata-token: $token")
        if [ $? -eq 0 ]; then
            export PUBLIC_IP6_ADDR="${public_ip6}"
            echo "Discovered PUBLIC_IP6_ADDR: ${PUBLIC_IP6_ADDR}"
        fi
    fi
fi

if [ "${OTEL_METADATA_DISCOVERY_METHOD}" = "gce_metadata" ]; then
    echo "Using GCE metadata to set OTEL metadata"

    instance_id=$(curl "http://metadata.google.internal/computeMetadata/v1/instance/id" -H "Metadata-Flavor: Google" -s)          # i.e. 5832583187537235075
    instance_name=$(curl "http://metadata.google.internal/computeMetadata/v1/instance/name" -H "Metadata-Flavor: Google" -s)      # i.e. relay-m5k7
    zone=$(curl "http://metadata.google.internal/computeMetadata/v1/instance/zone" -H "Metadata-Flavor: Google" -s | cut -d/ -f4) # i.e. us-east-1

    # Source for attribute names:
    # - https://opentelemetry.io/docs/specs/semconv/attributes-registry/service/
    # - https://opentelemetry.io/docs/specs/semconv/attributes-registry/gcp/#gcp---google-compute-engine-gce-attributes:
    export OTEL_RESOURCE_ATTRIBUTES="service.instance.id=${instance_id},gcp.gce.instance.name=${instance_name},cloud.region=${zone}"
    echo "Discovered OTEL metadata: ${OTEL_RESOURCE_ATTRIBUTES}"
fi

# If eBPF offloading is enabled, we need the source address to use for cross-stack relaying
if [ -n "${EBPF_OFFLOADING}" ]; then
    if [ -z "${EBPF_INT4_ADDR}" ]; then
        # Get the address of the EBPF_OFFLOADING interface used to reach the default gw
        EBPF_INT4_ADDR=$(ip -4 addr show dev "${EBPF_OFFLOADING}" | awk '/inet / {print $2}' | cut -d/ -f1)
        export EBPF_INT4_ADDR
    fi
    if [ -z "${EBPF_INT6_ADDR}" ]; then
        # Get the address of the EBPF_OFFLOADING interface used to reach the default gw
        EBPF_INT6_ADDR=$(ip -6 addr show dev "${EBPF_OFFLOADING}" scope global | awk '/inet6 / {print $2; exit}' | cut -d/ -f1)
        export EBPF_INT6_ADDR
    fi
fi

exec "$@"
