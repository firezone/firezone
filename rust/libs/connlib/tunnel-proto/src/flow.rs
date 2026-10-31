use std::net::{IpAddr, SocketAddr};
use std::num::NonZeroUsize;

use anyhow::{Context as _, Result};
use ip_packet::{IpPacket, Protocol, TcpFlags};

/// The 5-tuple of a packet whose routing decision later packets of the same flow can reuse.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Flow {
    src: IpAddr,
    dst: IpAddr,
    src_proto: Protocol,
    dst_proto: Protocol,
}

impl Flow {
    /// Returns the flow of `packet`, unless it changes the state of its flow.
    ///
    /// ICMP errors belong to the flow of the packet that failed and a TCP SYN, FIN or RST changes
    /// connection-tracking and NAT state, so they take the slow path.
    pub(crate) fn of(packet: &IpPacket) -> Option<Self> {
        if packet
            .tcp_flags()
            .is_some_and(|flags| flags.intersects(TcpFlags::SYN | TcpFlags::FIN | TcpFlags::RST))
        {
            return None;
        }

        Some(Self {
            src: packet.source(),
            dst: packet.destination(),
            src_proto: packet.source_protocol().ok()?,
            dst_proto: packet.destination_protocol().ok()?,
        })
    }
}

/// A batch of packets received on the TUN device that share one flow and thus one routing decision.
///
/// Holds the state borrowed until [`TunBatch::finish`] reserves the batch's WireGuard counters,
/// so no other packet or event can change the decision in between.
#[must_use = "no counters are reserved until the batch is finished"]
pub struct TunBatch<'a, S: flow_tracker::Scope> {
    /// The flow further packets must belong to; `None` admits no further packets.
    flow: Option<Flow>,
    /// The source rewrite of the first packet, applied to every further one.
    nat: Option<(Protocol, IpAddr)>,
    tunnel: snownet::EncapsulateBatch<'a>,
    flows: flow_tracker::FlowBatch,
    flow_tracker: &'a mut flow_tracker::Tracker<S>,
    len: NonZeroUsize,
}

impl<'a, S: flow_tracker::Scope> TunBatch<'a, S> {
    pub(crate) fn new(
        flow: Option<Flow>,
        nat: Option<(Protocol, IpAddr)>,
        tunnel: snownet::EncapsulateBatch<'a>,
        guard: flow_tracker::CurrentFlowGuard<'a, S>,
    ) -> Self {
        let (flows, flow_tracker) = guard.into_batch();

        Self {
            flow,
            nat,
            tunnel,
            flows,
            flow_tracker,
            len: NonZeroUsize::MIN,
        }
    }

    pub fn src(&self) -> Option<SocketAddr> {
        self.tunnel.src()
    }

    pub fn dst(&self) -> SocketAddr {
        self.tunnel.dst()
    }

    /// Returns the length of the datagram `packet` encrypts to.
    pub fn datagram_len(&self, packet: &IpPacket) -> usize {
        self.tunnel.datagram_len(packet)
    }

    /// Adds `packet` to the batch if it belongs to the batch's flow, translating it like the first one.
    ///
    /// Returns `false` and leaves `packet` untouched otherwise; finish the batch and begin a new
    /// one with the packet then.
    pub fn try_push(&mut self, packet: &mut IpPacket) -> bool {
        if self.flow.is_none() || Flow::of(packet) != self.flow {
            return false;
        }

        if let Some((proto, ip)) = self.nat
            && packet.translate_source(proto, ip).is_err()
        {
            return false;
        }

        self.flows.add(packet);
        self.len = self.len.saturating_add(1);

        true
    }

    /// Reserves the batch's counters and records its flow.
    pub fn finish(self) -> Result<snownet::PendingEncapsulate> {
        let encapsulation = self
            .tunnel
            .finish(self.len)
            .context("Failed to encapsulate")?;

        self.flow_tracker.insert_batch(self.flows);

        Ok(encapsulation)
    }
}
