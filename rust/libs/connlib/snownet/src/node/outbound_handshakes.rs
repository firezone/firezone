use std::collections::BTreeMap;

use anyhow::{Context, Result};
use boringtun::noise::{HandshakeResponse, Index, Packet, Tunn};

use crate::node::connection_state::PeerSocket;

/// Sockets used for outbound WireGuard handshakes, keyed by the
/// session component of our local sender index — see
/// [`boringtun::noise::Index`].
///
/// Populated on every [`HandshakeInit`](boringtun::noise::HandshakeInit) we emit,
/// with the outbound socket that frame rode on.
/// When the [`HandshakeResponse`](boringtun::noise::HandshakeResponse) lands and authenticates,
/// we look up the *write* path of that handshake — independent of where the
/// reply happened to arrive on, which makes us tolerant of
/// reorderings between concurrent handshakes on different paths.
///
/// Keyed by the 8-bit rotating session component (the global part is
/// constant per [`Tunn`]), so the map is bounded to 256 entries per
/// [`Connection`].
#[derive(Debug, Default)]
pub(crate) struct OutboundHandshakes {
    map: BTreeMap<u8, PeerSocket>,
}

impl OutboundHandshakes {
    /// Record the outbound socket for a fresh [`HandshakeInit`](boringtun::noise::HandshakeInit). Cheap
    /// and safe to call on any outbound WG byte slice: non-init frames
    /// are ignored.
    pub(crate) fn record(&mut self, packet: &[u8], socket: PeerSocket) {
        let Ok(Packet::HandshakeInit(_)) = Tunn::parse_incoming_packet(packet) else {
            return;
        };

        // `sender_idx` is private on both struct variants, so we read
        // it directly from the well-known wire layout (LE u32 at
        // offset 4..8). The parser above already validated the packet
        // is long enough.
        let bytes: [u8; 4] = packet[4..8]
            .try_into()
            .expect("validated packet has at least 8 bytes");
        let session = Index::from_peer(u32::from_le_bytes(bytes)).session() as u8;

        self.map.insert(session, socket);
    }

    /// Look up the outbound socket for an inbound [`HandshakeResponse`].
    ///
    /// Errors if no matching init was recorded — either we never sent
    /// it, or its entry rolled out of the 256-slot ring.
    pub(crate) fn get(&self, response: &HandshakeResponse) -> Result<PeerSocket> {
        let session = Index::from_peer(response.receiver_idx).session() as u8;

        self.map.get(&session).copied().with_context(|| {
            format!(
                "No socket for session index of HandshakeResponse (receiver_idx={})",
                response.receiver_idx
            )
        })
    }
}
