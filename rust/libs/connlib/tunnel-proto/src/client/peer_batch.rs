use std::net::SocketAddr;
use std::time::Instant;

use anyhow::Result;
use connlib_model::ClientOrGatewayId;
use ip_packet::IpPacket;

use super::ClientState;
use crate::batch::BatchingKey;
use smallvec::SmallVec;

/// The decision taken for the first packet of a flow in a [`PeerBatch`], reused for the rest.
pub(super) struct InboundDecision {
    pub(super) key: BatchingKey,
    pub(super) flow: flow_tracker::DetachedFlow,
}

/// The outcome of handling a message on the slow path.
pub(super) enum Handled {
    /// The packet to deliver, with the decision to reuse for the rest of its flow.
    Deliver(IpPacket, Option<InboundDecision>),
    Consumed,
    /// The peer said goodbye; the rest of the batch is dropped.
    Goodbye,
}

/// The data messages of one decrypted batch being handled, in order.
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
    decisions: SmallVec<[InboundDecision; 2]>,
    closed: bool,
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
            decisions: SmallVec::new(),
            closed: false,
        }
    }
}

impl Iterator for PeerBatch<'_> {
    type Item = Result<Option<IpPacket>>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.closed {
            return None;
        }

        let packets = &mut self.packets;
        let item = packets.next()?;

        let packet = item.as_ref().ok().and_then(Option::as_ref);
        let decision =
            packet.and_then(|packet| self.decisions.iter_mut().find(|d| d.key.matches(packet)));
        let Some((packet, decision)) = packet.zip(decision) else {
            let handled = self.state.handle_peer_message(
                packets.cid(),
                item,
                self.local,
                self.from,
                self.now,
            );

            return Some(handled.map(|handled| match handled {
                Handled::Deliver(packet, decision) => {
                    self.decisions.extend(decision);
                    Some(packet)
                }
                Handled::Consumed => None,
                Handled::Goodbye => {
                    self.closed = true;
                    None
                }
            }));
        };

        decision.flow.count_packet(packet);

        Some(item)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        if self.closed {
            return (0, Some(0));
        }

        (0, self.packets.size_hint().1)
    }
}

impl Drop for PeerBatch<'_> {
    fn drop(&mut self) {
        for decision in self.decisions.drain(..) {
            self.state.flow_tracker.insert_detached(decision.flow);
        }
    }
}
