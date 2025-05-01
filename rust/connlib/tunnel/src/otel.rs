pub mod attr {
    pub use firezone_telemetry::otel::attr::*;

    use opentelemetry::KeyValue;

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
}

pub use firezone_telemetry::otel::metrics;
