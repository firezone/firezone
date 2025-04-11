use ip_packet::IpPacket;
use opentelemetry::KeyValue;

// Recording discrete values can lead to a cardinality explosion.
// We only use metrics for local debugging and not in production.
// Locally, the set of ports will be small so we don't need to worry about this.
// If this ever changes, we need to be more clever here in classifying the protocol.
pub fn network_peer_port(p: u16) -> KeyValue {
    KeyValue::new("network.peer.port", p as i64)
}

pub fn network_transport_udp() -> KeyValue {
    KeyValue::new("network.transport", "udp")
}

pub fn network_type_for_packet(p: &IpPacket) -> KeyValue {
    match p {
        IpPacket::Ipv4(_) => network_type_ipv4(),
        IpPacket::Ipv6(_) => network_type_ipv6(),
    }
}

pub fn network_type_ipv4() -> KeyValue {
    KeyValue::new("network.type", "ipv4")
}

pub fn network_type_ipv6() -> KeyValue {
    KeyValue::new("network.type", "ipv6")
}

pub fn network_io_direction_receive() -> KeyValue {
    KeyValue::new("network.io.direction", "receive")
}

pub fn network_io_direction_transmit() -> KeyValue {
    KeyValue::new("network.io.direction", "transmit")
}
