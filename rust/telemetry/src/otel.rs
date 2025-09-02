use opentelemetry::KeyValue;
use opentelemetry_sdk::{
    Resource,
    resource::{EnvResourceDetector, ResourceDetector, TelemetryResourceDetector},
};

pub mod attr {
    use ip_packet::{IpPacket, IpVersion};
    use opentelemetry::Value;
    use sha2::Digest as _;
    use std::{io, net::SocketAddr, str::FromStr as _};

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
        let id = if uuid::Uuid::from_str(&maybe_legacy_id).is_ok() {
            hex::encode(sha2::Sha256::digest(&maybe_legacy_id))
        } else {
            maybe_legacy_id
        };

        KeyValue::new("service.instance.id", id)
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

impl<T> QueueLength for flume::WeakSender<T>
where
    T: Send + Sync + 'static,
{
    fn queue_length(&self) -> Option<u64> {
        let sender = self.upgrade()?;
        let len = sender.len();

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

pub struct OsResourceDetector;

impl ResourceDetector for OsResourceDetector {
    fn detect(&self) -> Resource {
        Resource::builder_empty()
            .with_attribute(KeyValue::new("os.type", std::env::consts::OS))
            .build()
    }
}
