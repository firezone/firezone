use std::time::Duration;

use opentelemetry::KeyValue;
use opentelemetry_sdk::{
    Resource,
    resource::{ResourceDetector, TelemetryResourceDetector},
};

pub mod attr {
    use ip_packet::IpPacket;
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

    pub fn service_instance_id(firezone_id: String) -> KeyValue {
        KeyValue::new("service.instance.id", firezone_id)
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
    use opentelemetry::metrics::Counter;

    pub fn network_packet_dropped() -> Counter<u64> {
        opentelemetry::global::meter("connlib")
            .u64_counter("network.packet.dropped")
            .with_description("Count of packets that are dropped or discarded")
            .with_unit("{packet}")
            .init()
    }

    pub fn network_packet_retransmitted() -> Counter<u64> {
        opentelemetry::global::meter("connlib")
            .u64_counter("network.packet.retransmitted")
            .with_description("Count of packets that are retransmitted")
            .with_unit("{packet}")
            .init()
    }
}

pub fn default_resource_with<const N: usize>(attributes: [KeyValue; N]) -> Resource {
    Resource::from_detectors(
        Duration::from_secs(0),
        vec![
            Box::new(TelemetryResourceDetector),
            Box::new(OsResourceDetector),
        ],
    )
    .merge(&Resource::new(attributes))
}

pub struct OsResourceDetector;

impl ResourceDetector for OsResourceDetector {
    fn detect(&self, _: Duration) -> Resource {
        Resource::new([KeyValue::new("os.type", std::env::consts::OS)])
    }
}
