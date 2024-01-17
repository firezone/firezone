#!/bin/sh

if [ "${FIREZONE_ENABLE_MASQUERADE}" = "1" ]; then
  IFACE="tun-firezone"
  # Enable masquerading for ethernet and wireless interfaces
  iptables-nft -A FORWARD -i $IFACE -j ACCEPT
  iptables-nft -A FORWARD -o $IFACE -j ACCEPT
  iptables-nft -t nat -A POSTROUTING -o eth+ -j MASQUERADE
  ip6tables-nft -A FORWARD -i $IFACE -j ACCEPT
  ip6tables-nft -A FORWARD -o $IFACE -j ACCEPT
  ip6tables-nft -t nat -A POSTROUTING -o eth+ -j MASQUERADE
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

exec $@
