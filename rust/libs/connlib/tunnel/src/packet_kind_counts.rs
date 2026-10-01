use tunnel_proto::packet_kind::{self, Kind};

/// Counts packets by their [`Kind`].
#[derive(Default)]
pub(crate) struct PacketKindCounts([u64; Kind::ALL.len()]);

impl PacketKindCounts {
    pub(crate) fn record(&mut self, packet: &[u8]) {
        self.0[packet_kind::classify(packet) as usize] += 1;
    }

    /// Returns the non-zero counts.
    pub(crate) fn non_zero(self) -> impl Iterator<Item = (Kind, u64)> {
        Kind::ALL
            .into_iter()
            .zip(self.0)
            .filter(|(_, count)| *count > 0)
    }
}
