use tunnel_proto::packet_kind::{self, Kind};

/// Counts packets by their [`Kind`].
#[derive(Default)]
pub(crate) struct PacketKindCounts([u64; Kind::ALL.len()]);

impl PacketKindCounts {
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
        self.0[kind as usize] += 1;
    }

    /// Returns the non-zero counts.
    pub(crate) fn non_zero(self) -> impl Iterator<Item = (Kind, u64)> {
        Kind::ALL
            .into_iter()
            .zip(self.0)
            .filter(|(_, count)| *count > 0)
    }
}
