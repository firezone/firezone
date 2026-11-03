use std::net::SocketAddr;
use std::time::Instant;

use anyhow::Result;
use connlib_model::ClientOrGatewayId;
use ip_packet::IpPacket;

use super::ClientState;
use crate::batch::BatchingKey;

/// The decision taken for the first packet of a flow in a [`PeerBatch`], reused for the rest.
pub(super) struct InboundDecision {
    pub(super) key: BatchingKey,
    pub(super) flows: flow_tracker::DetachedFlow,
}

pub(super) type InboundDecisions = smallvec::SmallVec<[InboundDecision; 2]>;

/// The data messages of one received datagram being handled, in order.
///
/// Dropping it records the flows of the batch.
#[must_use = "iterators are lazy and do nothing unless consumed"]
pub struct PeerBatch<'a> {
    state: &'a mut ClientState,
    packets: snownet::CommittedBatch<ClientOrGatewayId>,
    local: SocketAddr,
    from: SocketAddr,
    now: Instant,
    /// The routing decisions of the flows seen so far.
    decisions: InboundDecisions,
}

impl<'a> PeerBatch<'a> {
    pub(super) fn new(
        state: &'a mut ClientState,
        packets: snownet::CommittedBatch<ClientOrGatewayId>,
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
            decisions: InboundDecisions::new(),
        }
    }
}

impl Iterator for PeerBatch<'_> {
    type Item = Result<Option<IpPacket>>;

    fn next(&mut self) -> Option<Self::Item> {
        let packets = &mut self.packets;
        let item = packets.next()?;

        let packet = item.as_ref().ok().and_then(Option::as_ref);
        let decision =
            packet.and_then(|packet| self.decisions.iter_mut().find(|d| d.key.matches(packet)));
        let Some((packet, decision)) = packet.zip(decision) else {
            return Some(self.state.handle_peer_message(
                packets.cid(),
                item,
                &mut self.decisions,
                self.local,
                self.from,
                self.now,
            ));
        };

        decision.flows.count_packet(packet);

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
