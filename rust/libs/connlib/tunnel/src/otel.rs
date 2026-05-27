use std::sync::LazyLock;

use opentelemetry::{KeyValue, Value, metrics::Counter};

use crate::{FailedToHandleNetworkPacket, NotAllowedResource, NotClientIp};

pub mod attr {
    pub use telemetry::otel::attr::*;

    use opentelemetry::KeyValue;

    pub fn network_protocol_name(payload: &[u8]) -> KeyValue {
        const KEY: &str = "network.protocol.name";

        KeyValue::new(KEY, crate::packet_kind::classify(payload))
    }
}

pub use telemetry::otel::metrics;

/// Caps how many layers of an error's source chain are recorded as attributes.
const MAX_ERROR_LAYERS: usize = 5;

static EVENT_LOOP_ERRORS: LazyLock<Counter<u64>> = LazyLock::new(|| {
    opentelemetry::global::meter("connlib")
        .u64_counter("eventloop.error")
        .with_description("Number of errors encountered while processing a packet batch.")
        .with_unit("{error}")
        .build()
});

/// Records an error that surfaced from a single event-loop tick.
///
/// The source chain is encoded as per-layer `error.type.{N}` attributes, each a
/// low-cardinality token (an `io::ErrorKind` discriminant or the error's type name)
/// rather than its `Display`. Some errors embed per-flow data such as client IPs and
/// ports in their `Display`; recording those verbatim would explode the cardinality.
pub fn record_event_loop_error(error: &anyhow::Error) {
    EVENT_LOOP_ERRORS.add(1, &error_layers(error));
}

fn error_layers(error: &anyhow::Error) -> Vec<KeyValue> {
    error
        .chain()
        .take(MAX_ERROR_LAYERS)
        .enumerate()
        .map(|(layer, error)| KeyValue::new(format!("error.type.{layer}"), error_type(error)))
        .collect()
}

fn error_type(error: &(dyn std::error::Error + 'static)) -> Value {
    if let Some(error) = error.downcast_ref::<std::io::Error>() {
        return attr::io_error_type(error).value;
    }

    // The `Display` of these embeds per-flow data; use the type name as a stable token.
    if error.is::<FailedToHandleNetworkPacket>() {
        return Value::from("FailedToHandleNetworkPacket");
    }
    if error.is::<NotClientIp>() {
        return Value::from("NotClientIp");
    }
    if error.is::<NotAllowedResource>() {
        return Value::from("NotAllowedResource");
    }

    Value::from(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_source_chain_as_indexed_layers() {
        let error =
            anyhow::Error::new(std::io::Error::from(std::io::ErrorKind::NetworkUnreachable))
                .context("Failed to handle packet from TUN device");

        assert_eq!(
            error_layers(&error),
            vec![
                KeyValue::new("error.type.0", "Failed to handle packet from TUN device"),
                KeyValue::new("error.type.1", "io::ErrorKind::NetworkUnreachable"),
            ]
        );
    }

    #[test]
    fn normalises_errors_that_embed_per_flow_data() {
        let error = anyhow::Error::new(FailedToHandleNetworkPacket {
            local: "1.1.1.1:53".parse().unwrap(),
            from: "2.2.2.2:9999".parse().unwrap(),
        });

        assert_eq!(
            error_layers(&error),
            vec![KeyValue::new("error.type.0", "FailedToHandleNetworkPacket")]
        );
    }

    #[test]
    fn caps_number_of_recorded_layers() {
        let mut error = anyhow::Error::msg("root cause");
        for i in 0..(MAX_ERROR_LAYERS * 2) {
            error = error.context(format!("context {i}"));
        }

        assert_eq!(error_layers(&error).len(), MAX_ERROR_LAYERS);
    }
}
