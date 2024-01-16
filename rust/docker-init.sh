#!/bin/sh

if [ "${FIREZONE_ENABLE_MASQUERADE}" = "1" ]; then
  IFACE="tun-firezone"
  # Enable masquerading for ethernet and wireless interfaces
  iptables -C FORWARD -i $IFACE -j ACCEPT > /dev/null 2>&1 || iptables -A FORWARD -i $IFACE -j ACCEPT
  iptables -C FORWARD -o $IFACE -j ACCEPT > /dev/null 2>&1 || iptables -A FORWARD -o $IFACE -j ACCEPT
  iptables -t nat -C POSTROUTING -o e+ -j MASQUERADE > /dev/null 2>&1 || iptables -t nat -A POSTROUTING -o e+ -j MASQUERADE
  iptables -t nat -C POSTROUTING -o w+ -j MASQUERADE > /dev/null 2>&1 || iptables -t nat -A POSTROUTING -o w+ -j MASQUERADE
  ip6tables -C FORWARD -i $IFACE -j ACCEPT > /dev/null 2>&1 || ip6tables -A FORWARD -i $IFACE -j ACCEPT
  ip6tables -C FORWARD -o $IFACE -j ACCEPT > /dev/null 2>&1 || ip6tables -A FORWARD -o $IFACE -j ACCEPT
  ip6tables -t nat -C POSTROUTING -o e+ -j MASQUERADE > /dev/null 2>&1 || ip6tables -t nat -A POSTROUTING -o e+ -j MASQUERADE
  ip6tables -t nat -C POSTROUTING -o w+ -j MASQUERADE > /dev/null 2>&1 || ip6tables -t nat -A POSTROUTING -o w+ -j MASQUERADE
fi

if [ "${LISTEN_ADDRESS_DISCOVERY_METHOD}" = "gce_metadata" ]; then
  echo "Using GCE metadata to discover listen address"

  if [ "${PUBLIC_IP4_ADDR}" == "" ]; then
    export PUBLIC_IP4_ADDR=$(curl "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" -H "Metadata-Flavor: Google" -s)
    echo "Discovered PUBLIC_IP4_ADDR: ${PUBLIC_IP4_ADDR}"
  fi

  if [ "${PUBLIC_IP6_ADDR}" == "" ]; then
    export PUBLIC_IP6_ADDR=$(curl "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ipv6s" -H "Metadata-Flavor: Google" -s)
    echo "Discovered PUBLIC_IP6_ADDR: ${PUBLIC_IP6_ADDR}"
  fi
fi

exec $@
