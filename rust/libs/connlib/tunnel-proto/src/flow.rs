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
    /// Returns the flow of a TCP or UDP `packet`, unless it changes the state of its flow.
    ///
    /// A TCP SYN, FIN or RST changes connection-tracking and NAT state, so it takes the slow path.
    /// So does ICMP: an echo request and the echo reply going the same way share addresses and
    /// identifier, yet are routed and authorized differently.
    pub(crate) fn of(packet: &IpPacket) -> Option<Self> {
        if packet
            .tcp_flags()
            .is_some_and(|flags| flags.intersects(TcpFlags::SYN | TcpFlags::FIN | TcpFlags::RST))
        {
            return None;
        }

        let src_proto = packet.source_protocol().ok()?;
        let dst_proto = packet.destination_protocol().ok()?;
        if matches!(src_proto, Protocol::IcmpEcho(_)) {
            return None;
        }

        Some(Self {
            src: packet.source(),
            dst: packet.destination(),
            src_proto,
            dst_proto,
        })
    }
}

/// The most packets of a [`TunBatch`]: one GSO send carries at most 64 datagrams.
const MAX_LEN: usize = 64;

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
    flows: flow_tracker::FlowBatch<'a, S>,
    /// The packets of the batch, starting with the one that routed it.
    packets: Vec<IpPacket>,
}

impl<'a, S: flow_tracker::Scope> TunBatch<'a, S> {
    pub(crate) fn new(
        flow: Option<Flow>,
        nat: Option<(Protocol, IpAddr)>,
        tunnel: snownet::EncapsulateBatch<'a>,
        flows: flow_tracker::FlowBatch<'a, S>,
        packet: IpPacket,
    ) -> Self {
        let mut packets = Vec::with_capacity(MAX_LEN);
        packets.push(packet);

        Self {
            flow,
            nat,
            tunnel,
            flows,
            packets,
        }
    }

    /// Returns the packet the batch started with.
    pub fn first(&self) -> &IpPacket {
        &self.packets[0]
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

    /// Returns whether `packet` belongs to the batch's flow.
    pub fn accepts(&self, packet: &IpPacket) -> bool {
        self.flow.is_some() && Flow::of(packet) == self.flow
    }

    /// Adds `packet`, which the batch [accepts](Self::accepts), translating it like the first one.
    pub fn push(&mut self, mut packet: IpPacket) {
        if let Some((proto, ip)) = self.nat {
            let translated = packet.translate_source(proto, ip);

            // The first packet translated fine and this one shares its flow, thus its IP version.
            debug_assert!(translated.is_ok(), "{translated:?}");
        }

        self.flows.add(&packet);
        self.packets.push(packet);
    }

    /// Reserves the batch's counters and records its flow.
    pub fn finish(mut self) -> Result<(snownet::PendingEncapsulate, Vec<IpPacket>)> {
        let len = NonZeroUsize::new(self.packets.len()).expect("A batch starts with a packet");
        let encapsulation = match self.tunnel.finish(len) {
            Ok(encapsulation) => encapsulation,
            Err(e) => {
                self.flows.discard();

                return Err(e).context("Failed to encapsulate");
            }
        };

        self.flows.finish();

        Ok((encapsulation, self.packets))
    }
}
