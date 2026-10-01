use ip_packet::{IpPacket, IpVersion};
use opentelemetry::{KeyValue, metrics::Counter};
use tunnel_proto::packet_kind::{self, Kind};

use crate::otel;

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
        self.add(packet_kind::classify(packet));
    }

    /// Records a WireGuard data message, sent through a TURN channel if `relayed`.
    pub(crate) fn record_wireguard(&mut self, relayed: bool) {
        self.add(if relayed {
            Kind::WireguardOverTurn
        } else {
            Kind::Wireguard
        });
    }

    fn add(&mut self, kind: Kind) {
        self.counts[kind as usize] += 1;
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
