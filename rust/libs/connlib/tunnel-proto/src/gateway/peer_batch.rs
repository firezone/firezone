use std::net::SocketAddr;
use std::time::Instant;

use anyhow::{Context as _, Result};
use connlib_model::ClientId;
use ip_packet::IpPacket;

use super::{GatewayState, InboundDecisions, OutboundRewrite};
use crate::{FailedToDecapsulate, packet_kind};

impl GatewayState {
    /// Handles the WireGuard data messages decrypted from one [`snownet::PendingDecapsulate`].
    ///
    /// `local` and `from` are the addresses the datagram was received on and from. Packets of
    /// one flow reuse the routing decision of the flow's first packet in the batch.
    ///
    /// In case an item is `None`, you should call [`GatewayState::handle_timeout`] next to fully advance the internal state.
    pub fn handle_peer_batch(
        &mut self,
        decrypted: snownet::DecryptedBatch,
        local: SocketAddr,
        from: SocketAddr,
        now: Instant,
    ) -> Result<PeerBatch<'_>> {
        let packets = self
            .node
            .commit_decrypted(decrypted, now)
            .context(FailedToDecapsulate(packet_kind::Kind::Wireguard))?;

        Ok(PeerBatch {
            state: self,
            packets,
            local,
            from,
            now,
            decisions: InboundDecisions::new(),
        })
    }
}

/// The data messages of one received datagram being handled, in order.
///
/// Dropping it records the flows of the batch.
#[must_use = "iterators are lazy and do nothing unless consumed"]
pub struct PeerBatch<'a> {
    state: &'a mut GatewayState,
    packets: snownet::CommittedBatch<ClientId>,
    local: SocketAddr,
    from: SocketAddr,
    now: Instant,
    /// The routing decisions of the flows seen so far.
    decisions: InboundDecisions,
}

impl Iterator for PeerBatch<'_> {
    type Item = Result<Option<IpPacket>>;

    fn next(&mut self) -> Option<Self::Item> {
        let packets = &mut self.packets;
        let cid = packets.cid();
        let mut item = packets.next()?;

        let packet = item.as_mut().ok().and_then(Option::as_mut);
        let decision = packet
            .as_deref()
            .and_then(|packet| self.decisions.iter_mut().find(|d| d.key.matches(packet)));
        let Some((packet, decision)) = packet.zip(decision) else {
            return Some(self.state.handle_peer_message(
                cid,
                item,
                &mut self.decisions,
                self.local,
                self.from,
                self.now,
            ));
        };

        if let OutboundRewrite::Destination(proto, ip) = decision.rewrite
            && let Err(e) = packet
                .translate_destination(proto, ip)
                .context("Failed to translate packet to new destination")
        {
            return Some(Err(e));
        }

        decision.flows.add(packet);

        Some(item)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.packets.size_hint()
    }
}

impl Drop for PeerBatch<'_> {
    fn drop(&mut self) {
        for decision in self.decisions.drain(..) {
            self.state.flow_tracker.insert_detached(decision.flows);
        }
    }
}
