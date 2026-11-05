use std::net::SocketAddr;
use std::time::Instant;

use anyhow::{Context as _, Result};
use connlib_model::ClientId;
use ip_packet::IpPacket;

use super::{GatewayState, OutboundRewrite};
use crate::batch::BatchingKey;
use smallvec::SmallVec;

/// The decision taken for the first packet of a flow in a [`PeerBatch`], reused for the rest.
pub(super) struct InboundDecision {
    pub(super) key: BatchingKey,
    pub(super) rewrite: OutboundRewrite,
    pub(super) flow: flow_tracker::DetachedFlow,
}

/// The data messages of one decrypted batch being handled, in order.
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
    decisions: SmallVec<[InboundDecision; 2]>,
}

impl<'a> PeerBatch<'a> {
    pub(super) fn new(
        state: &'a mut GatewayState,
        packets: snownet::CommittedBatch<ClientId>,
        local: SocketAddr,
        from: SocketAddr,
        now: Instant,
    ) -> Self {
        Self {
            state,
            packets,
            local,
            from,
            now,
            decisions: SmallVec::new(),
        }
    }
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

        decision.flow.count_packet(packet);

        Some(item)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.packets.size_hint()
    }
}

impl Drop for PeerBatch<'_> {
    fn drop(&mut self) {
        for decision in self.decisions.drain(..) {
            self.state.flow_tracker.insert_detached(decision.flow);
        }
    }
}
