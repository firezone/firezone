pub mod attr {
    pub use telemetry::otel::attr::*;

    use opentelemetry::KeyValue;

    pub fn network_protocol_name(payload: &[u8]) -> KeyValue {
        const KEY: &str = "network.protocol.name";

        KeyValue::new(KEY, crate::packet_kind::classify(payload))
    }
}

pub use telemetry::otel::metrics;
