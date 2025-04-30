use opentelemetry::KeyValue;

pub mod attr {
    use ip_packet::IpPacket;
    use opentelemetry::Value;
    use std::{io, net::SocketAddr};

    use super::*;

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
}
