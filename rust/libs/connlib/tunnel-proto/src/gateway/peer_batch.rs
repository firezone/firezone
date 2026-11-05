use std::net::SocketAddr;
use std::time::Instant;

use anyhow::Result;
use connlib_model::ClientId;
use ip_packet::IpPacket;

use super::{GatewayState, OutboundRewrite};
use crate::batch::BatchingKey;
use crate::{FailedToDecapsulate, packet_kind};
use smallvec::SmallVec;

/// The decision taken for the first packet of a flow in a [`PeerBatch`], reused for the rest.
pub(super) struct Decision {
    pub(super) key: BatchingKey,
    pub(super) rewrite: OutboundRewrite,
    pub(super) flow: flow_tracker::DetachedFlow,
}

/// The outcome of handling a message on the slow path.
pub(super) enum PeerMessageOutcome {
    /// The packet to deliver, with the decision to reuse for the rest of its flow.
    Deliver(IpPacket, Option<Decision>),
    Consumed,
    /// The peer said goodbye; the rest of the batch is dropped.
    Goodbye,
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
    decisions: SmallVec<[Decision; 2]>,
    closed: bool,
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

        let cid = self.packets.cid();
        let mut packet = match self.packets.next()? {
            Ok(Some(packet)) => packet,
            Ok(None) => return Some(Ok(None)),
            Err(e) => {
                return Some(Err(
                    e.context(FailedToDecapsulate(packet_kind::Kind::Wireguard))
                ));
            }
        };

        let Some(decision) = self.decisions.iter_mut().find(|d| d.key.matches(&packet)) else {
            let handled = self
                .state
                .handle_peer_message(cid, packet, self.local, self.from, self.now);

            return Some(handled.map(|handled| match handled {
                PeerMessageOutcome::Deliver(packet, decision) => {
                    self.decisions.extend(decision);
                    Some(packet)
                }
                PeerMessageOutcome::Consumed => None,
                PeerMessageOutcome::Goodbye => {
                    self.closed = true;
                    None
                }
            }));
        };

        if let OutboundRewrite::Destination(proto, ip) = decision.rewrite {
            let translated = packet.translate_destination(proto, ip);

            // The first packet translated fine and this one shares its flow, thus its IP version.
            debug_assert!(translated.is_ok(), "{translated:?}");
        }

        decision.flow.count_packet(&packet);

        Some(Ok(Some(packet)))
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
