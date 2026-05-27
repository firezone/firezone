use opentelemetry::{KeyValue, Value, metrics::Counter};
use smallvec::SmallVec;

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

/// Pre-computed attribute keys, one per recorded error-chain layer.
const ERROR_TYPE_KEYS: [&str; MAX_ERROR_LAYERS] = [
    "error.type.0",
    "error.type.1",
    "error.type.2",
    "error.type.3",
    "error.type.4",
];

/// Counter for errors encountered while processing a single packet batch.
pub(crate) fn event_loop_errors() -> Counter<u64> {
    opentelemetry::global::meter("connlib")
        .u64_counter("eventloop.error")
        .with_description("Number of errors encountered while processing a packet batch.")
        .with_unit("{error}")
        .build()
}

/// Encodes an error's source chain into per-layer `error.type.{N}` attributes.
///
/// Each layer is a low-cardinality token rather than the error's `Display`/`Debug` body,
/// which can embed per-flow data such as client IPs that would otherwise explode the
/// metric's cardinality.
pub(crate) fn error_layers(error: &anyhow::Error) -> SmallVec<[KeyValue; MAX_ERROR_LAYERS]> {
    error
        .chain()
        .zip(ERROR_TYPE_KEYS)
        .map(|(error, key)| KeyValue::new(key, error_type(error)))
        .collect()
}

fn error_type(error: &(dyn std::error::Error + 'static)) -> Value {
    // The kind is stable, whereas the `Debug` of `io::Error` includes the OS message.
    if let Some(io) = error.downcast_ref::<std::io::Error>() {
        return attr::io_error_type(io).value;
    }

    // Derived `Debug` renders as `TypeName { .. }` or `TypeName(..)`. Keep only the leading
    // type/variant name so the values inside the brackets don't leak into the metric.
    let debug = format!("{error:?}");
    let name = match debug.split_once(['{', '(']) {
        Some((name, _)) => name.trim_end(),
        None => debug.trim_end(),
    };

    Value::from(name.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{FailedToHandleNetworkPacket, NotClientIp};

    #[test]
    fn io_error_uses_error_kind() {
        let error =
            anyhow::Error::new(std::io::Error::from(std::io::ErrorKind::NetworkUnreachable));

        assert_eq!(
            error_layers(&error)[0],
            KeyValue::new("error.type.0", "io::ErrorKind::NetworkUnreachable")
        );
    }

    #[test]
    fn struct_error_keeps_only_type_name() {
        let error = anyhow::Error::new(FailedToHandleNetworkPacket {
            local: "1.1.1.1:53".parse().unwrap(),
            from: "2.2.2.2:9999".parse().unwrap(),
        });

        assert_eq!(
            error_layers(&error)[0],
            KeyValue::new("error.type.0", "FailedToHandleNetworkPacket")
        );
    }

    #[test]
    fn tuple_error_strips_parenthesised_fields() {
        let error = anyhow::Error::new(NotClientIp("1.2.3.4".parse().unwrap()));

        assert_eq!(
            error_layers(&error)[0],
            KeyValue::new("error.type.0", "NotClientIp")
        );
    }

    #[test]
    fn caps_recorded_layers() {
        let mut error = anyhow::Error::msg("root cause");
        for i in 0..(MAX_ERROR_LAYERS * 2) {
            error = error.context(format!("context {i}"));
        }

        assert_eq!(error_layers(&error).len(), MAX_ERROR_LAYERS);
    }
}
