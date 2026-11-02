use anyhow::ErrorExt as _;
use ip_packet::{IpPacket, IpVersion};
use opentelemetry::{KeyValue, metrics::Counter};
use tunnel_proto::UnroutablePacket;
use tunnel_proto::packet_kind::{self, Kind};
use tunnel_proto::unroutable_packet::RoutingError;

use crate::otel;

/// Counts the packets read from the TUN device that could not be routed.
pub(crate) struct DroppedPackets(Counter<u64>);

impl DroppedPackets {
    pub(crate) fn new() -> Self {
        Self(otel_instruments::network_packet_dropped())
    }

    /// Counts the packet that failed with `error`, by the reason it was unroutable.
    #[cold]
    #[inline(never)]
    pub(crate) fn record(&self, error: &anyhow::Error) {
        let routing_error = error
            .any_downcast_ref::<UnroutablePacket>()
            .map(|e| e.reason())
            .unwrap_or(RoutingError::Other);

        // TODO: Include more attributes here like IPv4/IPv6?
        self.0.add(
            1,
            &[
                otel::attr::error_type(routing_error),
                otel::attr::network_io_direction_receive(),
            ],
        );
    }
}

/// Counts UDP packets by their [`Kind`] and adds them to `counter` when dropped.
pub(crate) struct UdpPacketCounts<'a> {
    counter: &'a Counter<u64>,
    direction: KeyValue,
    counts: [u64; Kind::ALL.len()],
}

impl<'a> UdpPacketCounts<'a> {
    pub(crate) fn receive(counter: &'a Counter<u64>) -> Self {
        Self::new(counter, otel::attr::network_io_direction_receive())
    }

    pub(crate) fn transmit(counter: &'a Counter<u64>) -> Self {
        Self::new(counter, otel::attr::network_io_direction_transmit())
    }

    fn new(counter: &'a Counter<u64>, direction: KeyValue) -> Self {
        Self {
            counter,
            direction,
            counts: [0; Kind::ALL.len()],
        }
    }

    pub(crate) fn record(&mut self, packet: &[u8]) {
        self.counts[packet_kind::classify(packet) as usize] += 1;
    }
}

impl Drop for UdpPacketCounts<'_> {
    fn drop(&mut self) {
        for (kind, count) in Kind::ALL.into_iter().zip(self.counts) {
            if count == 0 {
                continue;
            }

            self.counter.add(
                count,
                &[
                    otel::attr::network_protocol_name(kind),
                    otel::attr::network_transport_udp(),
                    self.direction.clone(),
                ],
            );
        }
    }
}

/// Counts IP packets read from or written to the TUN device by their IP version and adds them to
/// `counter` when dropped.
pub(crate) struct TunPacketCounts<'a> {
    counter: &'a Counter<u64>,
    direction: KeyValue,
    ipv4: u64,
    ipv6: u64,
}

impl<'a> TunPacketCounts<'a> {
    pub(crate) fn receive(counter: &'a Counter<u64>) -> Self {
        Self::new(counter, otel::attr::network_io_direction_receive())
    }

    pub(crate) fn transmit(counter: &'a Counter<u64>) -> Self {
        Self::new(counter, otel::attr::network_io_direction_transmit())
    }

    fn new(counter: &'a Counter<u64>, direction: KeyValue) -> Self {
        Self {
            counter,
            direction,
            ipv4: 0,
            ipv6: 0,
        }
    }

    pub(crate) fn record(&mut self, packet: &IpPacket) {
        match packet.version() {
            IpVersion::V4 => self.ipv4 += 1,
            IpVersion::V6 => self.ipv6 += 1,
        }
    }
}

impl Drop for TunPacketCounts<'_> {
    fn drop(&mut self) {
        for (count, network_type) in [
            (self.ipv4, otel::attr::network_type_ipv4()),
            (self.ipv6, otel::attr::network_type_ipv6()),
        ] {
            if count == 0 {
                continue;
            }

            self.counter
                .add(count, &[network_type, self.direction.clone()]);
        }
    }
}
