use ip_packet::IpPacket;
use opentelemetry::KeyValue;

pub fn network_transport_udp() -> KeyValue {
    KeyValue::new("network.transport", "udp")
}

pub fn network_type_for_packet(p: &IpPacket) -> KeyValue {
    match p {
        IpPacket::Ipv4(_) => network_type_ipv4(),
        IpPacket::Ipv6(_) => network_type_ipv6(),
    }
}

pub fn network_protocol_name(payload: &[u8]) -> KeyValue {
    const KEY: &str = "network.protocol.name";

    match payload {
        [0..3, ..] => KeyValue::new(KEY, "stun"),
        // Channel-data is a 4-byte header so the actual payload starts on the 5th byte
        [64..=79, _, _, _, 0..3, ..] => KeyValue::new(KEY, "stun-over-turn"),
        [64..=79, _, _, _, payload @ ..] if snownet::is_wireguard(payload) => {
            KeyValue::new(KEY, "wireguard-over-turn")
        }
        [64..=79, _, _, _, ..] => KeyValue::new(KEY, "unknown-over-turn"),
        payload if snownet::is_wireguard(payload) => KeyValue::new(KEY, "wireguard"),
        _ => KeyValue::new(KEY, "unknown"),
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
