use opentelemetry::{KeyValue, Value};
use opentelemetry_sdk::{
    Resource,
    metrics::SdkMeterProvider,
    resource::{EnvResourceDetector, ResourceDetector, TelemetryResourceDetector},
};

use crate::{MaybePushMetricsExporter, SentryMetricExporter, feature_flags};

pub mod attr {
    use ip_packet::{IpPacket, IpVersion};
    use opentelemetry::Value;
    use std::{io, net::SocketAddr};

    use super::*;

    #[macro_export]
    macro_rules! service_name {
        () => {
            ::opentelemetry::KeyValue::new("service.name", env!("CARGO_PKG_NAME"))
        };
    }

    #[macro_export]
    macro_rules! service_version {
        () => {
            ::opentelemetry::KeyValue::new("service.version", env!("CARGO_PKG_VERSION"))
        };
    }

    pub use service_name;
    pub use service_version;

    pub fn service_instance_id(maybe_legacy_id: String) -> KeyValue {
        KeyValue::new(
            "service.instance.id",
            crate::maybe_hash_device_id(maybe_legacy_id),
        )
    }

    pub fn network_transport_udp() -> KeyValue {
        KeyValue::new("network.transport", "udp")
    }

    pub fn network_type_for_packet(p: &IpPacket) -> KeyValue {
        match p.version() {
            IpVersion::V4 => network_type_ipv4(),
            IpVersion::V6 => network_type_ipv6(),
        }
    }

    pub fn network_type_for_addr(addr: SocketAddr) -> KeyValue {
        match addr {
            SocketAddr::V4(_) => network_type_ipv4(),
            SocketAddr::V6(_) => network_type_ipv6(),
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

    pub fn io_error_code(e: &io::Error) -> KeyValue {
        KeyValue::new("error.code", e.raw_os_error().unwrap_or_default() as i64)
    }

    pub fn io_error_type(e: &io::Error) -> KeyValue {
        error_type(format!("io::ErrorKind::{:?}", e.kind()))
    }

    pub fn error_type(value: impl Into<Value>) -> KeyValue {
        KeyValue::new("error.type", value)
    }

    pub fn queue_item_ip_packet() -> KeyValue {
        KeyValue::new("queue.item", "ip-packet")
    }

    pub fn queue_item_gro_batch() -> KeyValue {
        KeyValue::new("queue.item", "udp-gro-batch")
    }

    pub fn queue_item_gso_batch() -> KeyValue {
        KeyValue::new("queue.item", "udp-gso-batch")
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn io_error_type_serialisation() {
            let error = io::Error::from(io::ErrorKind::NetworkUnreachable);

            assert_eq!(
                io_error_type(&error),
                KeyValue::new("error.type", "io::ErrorKind::NetworkUnreachable")
            );
        }
    }
}

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

/// Encodes an error's source chain into per-layer `error.type.{N}` attributes.
///
/// Each layer is a low-cardinality token rather than the error's `Display`/`Debug` body,
/// which can embed per-flow data such as client IPs that would otherwise explode the
/// metric's cardinality.
pub fn error_layers(error: &anyhow::Error) -> Vec<KeyValue> {
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
mod error_layer_tests {
    use super::*;

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
        let error = anyhow::Error::new(StructError {
            client_ip: "1.2.3.4",
        });

        assert_eq!(
            error_layers(&error)[0],
            KeyValue::new("error.type.0", "StructError")
        );
    }

    #[test]
    fn tuple_error_strips_parenthesised_fields() {
        let error = anyhow::Error::new(TupleError("1.2.3.4"));

        assert_eq!(
            error_layers(&error)[0],
            KeyValue::new("error.type.0", "TupleError")
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

    #[derive(Debug, thiserror::Error)]
    #[error("failed to handle packet from {client_ip}")]
    struct StructError {
        client_ip: &'static str,
    }

    #[derive(Debug, thiserror::Error)]
    #[error("{0} is not a client IP")]
    struct TupleError(&'static str);
}

pub mod metrics {
    use std::{ops::ControlFlow, time::Duration};

    use opentelemetry::{
        KeyValue,
        metrics::{Counter, Gauge},
    };

    use crate::otel::QueueLength;

    pub fn network_packet_dropped() -> Counter<u64> {
        opentelemetry::global::meter("connlib")
            .u64_counter("network.packet.dropped")
            .with_description("Count of packets that are dropped or discarded")
            .with_unit("{packet}")
            .build()
    }

    pub fn tunnel_errors() -> Counter<u64> {
        opentelemetry::global::meter("connlib")
            .u64_counter("tunnel.error")
            .with_description("Number of errors encountered while processing a packet batch.")
            .with_unit("{error}")
            .build()
    }

    pub async fn periodic_system_queue_length<const N: usize>(
        queue: impl QueueLength,
        attributes: [KeyValue; N],
    ) {
        let gauge = opentelemetry::global::meter("connlib")
            .u64_gauge("system.queue.length")
            .with_description("The length of a queue.")
            .build();

        periodic_gauge(
            gauge,
            |gauge| {
                let len = match queue.queue_length() {
                    Some(len) => len,
                    None => return ControlFlow::Break(()),
                };

                gauge.record(len, &attributes);

                ControlFlow::Continue(())
            },
            Duration::from_secs(1),
        )
        .await;
    }

    pub async fn periodic_gauge<T>(
        gauge: Gauge<T>,
        callback: impl Fn(&Gauge<T>) -> ControlFlow<(), ()>,
        interval: Duration,
    ) {
        while callback(&gauge).is_continue() {
            tokio::time::sleep(interval).await;
        }
    }
}

pub trait QueueLength: Send + Sync + 'static {
    fn queue_length(&self) -> Option<u64>;
}

impl<T> QueueLength for tokio::sync::mpsc::WeakSender<T>
where
    T: Send + Sync + 'static,
{
    fn queue_length(&self) -> Option<u64> {
        let sender = self.upgrade()?;
        let len = sender.max_capacity() - sender.capacity();

        Some(len as u64)
    }
}

pub fn default_resource_with<const N: usize>(attributes: [KeyValue; N]) -> Resource {
    Resource::builder_empty()
        .with_detector(Box::new(TelemetryResourceDetector))
        .with_detector(Box::new(OsResourceDetector))
        .with_detector(Box::new(EnvResourceDetector::new()))
        .with_attributes(attributes)
        .build()
}

/// Installs a global meter provider that streams metrics into Sentry.
///
/// Export is gated on the `stream_metrics` feature flag, so it is safe to call
/// this unconditionally when starting telemetry.
pub fn install_sentry_meter_provider(
    service_name: &'static str,
    service_version: &'static str,
    service_instance_id: String,
) {
    let resource = default_resource_with([
        KeyValue::new("service.name", service_name),
        KeyValue::new("service.version", service_version),
        crate::otel::attr::service_instance_id(service_instance_id),
    ]);

    let provider = SdkMeterProvider::builder()
        .with_periodic_exporter(MaybePushMetricsExporter {
            inner: SentryMetricExporter,
            should_export: feature_flags::stream_metrics,
        })
        .with_resource(resource)
        .build();

    opentelemetry::global::set_meter_provider(provider);
}

pub struct OsResourceDetector;

impl ResourceDetector for OsResourceDetector {
    fn detect(&self) -> Resource {
        Resource::builder_empty()
            .with_attribute(KeyValue::new("os.type", std::env::consts::OS))
            .build()
    }
}
