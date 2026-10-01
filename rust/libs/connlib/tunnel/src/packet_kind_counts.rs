use opentelemetry::{KeyValue, metrics::Counter};
use tunnel_proto::packet_kind::{self, Kind};

use crate::otel;

/// Counts UDP packets by their [`Kind`] and adds them to `counter` when dropped.
pub(crate) struct PacketKindCounts<'a> {
    counter: &'a Counter<u64>,
    direction: KeyValue,
    counts: [u64; Kind::ALL.len()],
}

impl<'a> PacketKindCounts<'a> {
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

impl Drop for PacketKindCounts<'_> {
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
