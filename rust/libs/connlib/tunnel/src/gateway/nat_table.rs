//! A stateful symmetric NAT table that performs conversion between a client's picked proxy ip and the actual resource's IP.
use anyhow::{Context, Result};
use bimap::BiMap;
use ip_packet::{FailedPacket, IcmpError, IpPacket, PacketBuilder, Protocol};
use std::collections::{BTreeMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::time::{Duration, Instant};

/// This stateful NAT table converts a client's proxy OP for a domain name into a real IP for the domain.
///
/// The NAT operates on tuples of "source protocol" and IP.
/// "source protocol" here is a component from OSI-4, i.e. UDP, TCP or ICMP.
/// NATing packets with a different protocol is not supported.
///
/// We need to include the L4 component because multiple DNS resources could resolve to the same IP on the Internet.
/// Thus, purely an L3 NAT would not be sufficient as it would be impossible to map back to the proxy IP.
#[derive(Default, Debug)]
pub(crate) struct NatTable {
    table: BiMap<Inside, Outside>,
    state_by_inside: BTreeMap<Inside, EntryState>,

    // We don't bother with proactively freeing this because a single entry is only ~20 bytes and it gets cleanup once the connection to the client goes away.
    expired: HashSet<Outside>,
}

#[derive(Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Clone, Copy)]
struct Inside(Protocol, IpAddr);

impl Inside {
    fn into_inner(self) -> (Protocol, IpAddr) {
        (self.0, self.1)
    }
}

#[derive(Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Clone, Copy)]
struct Outside(Protocol, IpAddr);

impl Outside {
    fn into_inner(self) -> (Protocol, IpAddr) {
        (self.0, self.1)
    }
}

pub(crate) const TCP_TTL: Duration = Duration::from_secs(60 * 60 * 2);
pub(crate) const UDP_TTL: Duration = Duration::from_secs(60 * 2);
pub(crate) const ICMP_TTL: Duration = Duration::from_secs(60 * 2);

pub(crate) const UNCONFIRMED_TTL: Duration = Duration::from_secs(60);

impl NatTable {
    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        let expired = self.state_by_inside.extract_if(.., |inside, state| {
            state
                .remove_at(inside.0)
                .is_some_and(|remove_at| now >= remove_at)
        });

        for (inside, state) in expired {
            let Some((_, outside)) = self.table.remove_by_left(&inside) else {
                continue;
            };

            self.expired.insert(outside);

            let last_outgoing = now.duration_since(state.last_outgoing);
            let last_incoming = state.last_incoming.map(|t| now.duration_since(t));

            tracing::debug!(
                ?inside,
                ?outside,
                ?last_outgoing,
                ?last_incoming,
                fin_tx = %state.outgoing_fin,
                fin_rx = %state.incoming_fin,
                rst_tx = %state.outgoing_rst,
                rst_rx = %state.incoming_rst,
                "NAT entry removed"
            );
        }
    }

    pub(crate) fn translate_outgoing(
        &mut self,
        packet: &IpPacket,
        outside_dst: IpAddr,
        now: Instant,
    ) -> Result<(Protocol, IpAddr)> {
        let src = packet.source_protocol()?;
        let dst = packet.destination();

        let inside = Inside(src, dst);

        if let Some(outside) = self.table.get_by_left(&inside).copied()
            && let Some(state) = self.state_by_inside.get_mut(&inside)
        {
            tracing::trace!(?inside, ?outside, ?state, "Translating outgoing packet");

            if packet.as_tcp().is_some_and(|tcp| tcp.rst()) {
                state.outgoing_rst = true;
            }

            if packet.as_tcp().is_some_and(|tcp| tcp.fin()) {
                state.outgoing_fin = true;
            }

            state.last_outgoing = now;

            return Ok(outside.into_inner());
        }

        // Find the first available public port, starting from the port of the to-be-mapped packet.
        // This will re-assign the same port in most cases, even after the mapping expires.
        let outside = (src.value()..=u16::MAX)
            .chain(1..src.value())
            .map(|p| Outside(src.with_value(p), outside_dst))
            .find(|outside| !self.table.contains_right(outside))
            .context("Exhausted NAT")?;

        self.table.insert(inside, outside);
        self.state_by_inside.insert(inside, EntryState::new(now));
        self.expired.remove(&outside);

        tracing::debug!(?inside, ?outside, "New NAT session");

        Ok(outside.into_inner())
    }

    pub(crate) fn translate_incoming(
        &mut self,
        packet: &IpPacket,
        now: Instant,
    ) -> Result<TranslateIncomingResult> {
        if let Some((failed_packet, icmp_error)) = packet.icmp_error()? {
            let outside = Outside(failed_packet.src_proto(), failed_packet.dst());

            if let Some(Inside(inside_proto, inside_dst)) =
                self.translate_incoming_inner(&outside, now)
            {
                return Ok(TranslateIncomingResult::IcmpError(IcmpErrorPrototype {
                    inside_dst,
                    inside_proto,
                    failed_packet,
                    icmp_error,
                }));
            }

            if self.expired.contains(&outside) {
                return Ok(TranslateIncomingResult::ExpiredNatSession);
            }

            return Ok(TranslateIncomingResult::NoNatSession);
        }

        let outside = Outside(packet.destination_protocol()?, packet.source());

        if let Some(inside) = self.translate_incoming_inner(&outside, now)
            && let Some(state) = self.state_by_inside.get_mut(&inside)
        {
            if packet.as_tcp().is_some_and(|tcp| tcp.rst()) {
                state.incoming_rst = true;
            }

            if packet.as_tcp().is_some_and(|tcp| tcp.fin()) {
                state.incoming_fin = true;
            }

            let (proto, src) = inside.into_inner();

            return Ok(TranslateIncomingResult::Ok { proto, src });
        }

        if self.expired.contains(&outside) {
            return Ok(TranslateIncomingResult::ExpiredNatSession);
        }

        Ok(TranslateIncomingResult::NoNatSession)
    }

    fn translate_incoming_inner(&mut self, outside: &Outside, now: Instant) -> Option<Inside> {
        let inside = self.table.get_by_right(outside)?;
        let state = self.state_by_inside.get_mut(inside)?;

        tracing::trace!(?inside, ?outside, ?state, "Translating incoming packet");

        let prev_last_incoming = state.last_incoming.replace(now);
        if prev_last_incoming.is_none() {
            tracing::debug!(?inside, ?outside, "NAT session confirmed");
        }

        Some(*inside)
    }
}

#[derive(Debug)]
struct EntryState {
    last_outgoing: Instant,
    last_incoming: Option<Instant>,

    outgoing_rst: bool,
    incoming_rst: bool,
    outgoing_fin: bool,
    incoming_fin: bool,
}

impl EntryState {
    fn new(last_outgoing: Instant) -> Self {
        Self {
            last_outgoing,
            last_incoming: None,
            outgoing_rst: false,
            incoming_rst: false,
            outgoing_fin: false,
            incoming_fin: false,
        }
    }

    fn ttl_timeout(&self, protocol: Protocol) -> Instant {
        let ttl = match protocol {
            Protocol::Tcp(_) => TCP_TTL,
            Protocol::Udp(_) => UDP_TTL,
            Protocol::IcmpEcho(_) => ICMP_TTL,
        };

        self.last_packet() + ttl
    }

    fn unconfirmed_timeout(&self) -> Option<Instant> {
        if self.last_incoming.is_some() {
            return None;
        }

        Some(self.last_outgoing + UNCONFIRMED_TTL)
    }

    fn fin_timeout(&self) -> Option<Instant> {
        if !self.outgoing_fin || !self.incoming_fin {
            return None;
        }

        Some(self.last_packet() + Duration::from_secs(5)) // Keep NAT open for a few more seconds.
    }

    fn rst_timeout(&self) -> Option<Instant> {
        if !self.outgoing_rst && !self.incoming_rst {
            return None;
        }

        Some(self.last_packet()) // Close immediately.
    }

    fn remove_at(&self, protocol: Protocol) -> Option<Instant> {
        std::iter::empty()
            .chain(Some(self.ttl_timeout(protocol)))
            .chain(self.unconfirmed_timeout())
            .chain(self.fin_timeout())
            .chain(self.rst_timeout())
            .min()
    }

    fn last_packet(&self) -> Instant {
        let Some(last_incoming) = self.last_incoming else {
            return self.last_outgoing;
        };

        std::cmp::max(self.last_outgoing, last_incoming)
    }
}

/// A prototype for an ICMP error packet.
///
/// A packet coming in from the "outside" of the NAT may be an ICMP error.
/// In that case, our regular NAT lookup will fail as that one relies on Layer-4 protocol (TCP/UDP port or ICMP identifier).
///
/// ICMP error messages contain a part of the original IP packet that could not be routed.
/// In order for the NAT to be transparent, the IP and protocol layer within that original packet also need to be translated.
#[derive(Debug, PartialEq, Eq)]
pub struct IcmpErrorPrototype {
    /// The "original" destination IP that could not be reached.
    ///
    /// This is a "proxy IP" as generated by the Firezone client during DNS resolution.
    inside_dst: IpAddr,
    inside_proto: Protocol,

    icmp_error: IcmpError,

    failed_packet: FailedPacket,
}

impl IcmpErrorPrototype {
    /// Turns this prototype into an actual ICMP error IP packet, targeting the given IPv4/IPv6 address, depending on the original Resource address.
    pub fn into_packet(self, dst_v4: Ipv4Addr, dst_v6: Ipv6Addr) -> Result<IpPacket> {
        // First, translate the failed packet as if it would have directly originated from the client (without our NAT applied).
        let original_packet = self
            .failed_packet
            .translate_destination(self.inside_dst, self.inside_proto)
            .context("Failed to translate unroutable packet within ICMP error")?;

        // Second, generate an ICMP error that originates from the originally addressed Resource.
        match self.inside_dst {
            IpAddr::V4(inside_dst) => {
                let icmp_type = self.icmp_error.into_icmp_v4_type()?;
                let icmpv4 =
                    PacketBuilder::ipv4(inside_dst.octets(), dst_v4.octets(), 20).icmpv4(icmp_type);

                ip_packet::build!(icmpv4, original_packet)
            }
            IpAddr::V6(inside_dst) => {
                let icmp_type = self.icmp_error.into_icmp_v6_type()?;
                let icmpv6 =
                    PacketBuilder::ipv6(inside_dst.octets(), dst_v6.octets(), 20).icmpv6(icmp_type);

                ip_packet::build!(icmpv6, original_packet)
            }
        }
    }

    pub fn error(&self) -> &IcmpError {
        &self.icmp_error
    }

    pub fn inside_dst(&self) -> IpAddr {
        self.inside_dst
    }

    pub fn outside_dst(&self) -> IpAddr {
        self.failed_packet.dst()
    }
}

#[derive(Debug, PartialEq)]
pub enum TranslateIncomingResult {
    Ok { proto: Protocol, src: IpAddr },
    IcmpError(IcmpErrorPrototype),
    ExpiredNatSession,
    NoNatSession,
}

#[cfg(all(test, feature = "proptest"))]
mod tests {
    use super::*;
    use ip_packet::{IpPacket, make::TcpFlags, proptest::*};
    use proptest::prelude::*;

    #[test_strategy::proptest(ProptestConfig { max_local_rejects: 10_000, max_global_rejects: 10_000, ..ProptestConfig::default() })]
    fn translates_back_and_forth_packet(
        #[strategy(udp_or_tcp_or_icmp_packet())] packet: IpPacket,
        #[strategy(any::<IpAddr>())] outside_dst: IpAddr,
        #[strategy(0..15000u64)] response_delay: u64,
    ) {
        proptest::prop_assume!(packet.destination().is_ipv4() == outside_dst.is_ipv4()); // Required for our test to simulate a response.

        let mut now = Instant::now();
        let mut table = NatTable::default();
        let response_delay = Duration::from_secs(response_delay);

        // Remember original src_p and dst
        let src = packet.source_protocol().unwrap();
        let dst = packet.destination();

        // Translate out
        let (new_source_protocol, new_dst_ip) =
            table.translate_outgoing(&packet, outside_dst, now).unwrap();

        // Pretend we are getting a response.
        let mut response = packet.clone();
        response.set_destination_protocol(new_source_protocol.value());
        response.set_src(new_dst_ip).unwrap();

        // Update time.
        now += Duration::from_secs(1);
        table.handle_timeout(now);

        // Confirm mapping
        table.translate_incoming(&response.clone(), now).unwrap();

        // Simulate another packet after _response_delay_
        now += response_delay;
        table.handle_timeout(now);
        let translate_incoming = table.translate_incoming(&response, now).unwrap();

        let ttl = match src {
            Protocol::Tcp(_) => 7200,
            Protocol::Udp(_) => 120,
            Protocol::IcmpEcho(_) => 120,
        };

        // Assert
        if response_delay >= Duration::from_secs(ttl) {
            assert_eq!(
                translate_incoming,
                TranslateIncomingResult::ExpiredNatSession
            );
        } else {
            assert_eq!(
                translate_incoming,
                TranslateIncomingResult::Ok {
                    proto: src,
                    src: dst
                }
            );
        }
    }

    #[test_strategy::proptest(ProptestConfig { max_local_rejects: 10_000, max_global_rejects: 10_000, ..ProptestConfig::default() })]
    fn can_handle_multiple_packets(
        #[strategy(udp_or_tcp_or_icmp_packet())] packet1: IpPacket,
        #[strategy(any::<IpAddr>())] outside_dst1: IpAddr,
        #[strategy(udp_or_tcp_or_icmp_packet())] packet2: IpPacket,
        #[strategy(any::<IpAddr>())] outside_dst2: IpAddr,
    ) {
        proptest::prop_assume!(packet1.destination().is_ipv4() == outside_dst1.is_ipv4()); // Required for our test to simulate a response.
        proptest::prop_assume!(packet2.destination().is_ipv4() == outside_dst2.is_ipv4()); // Required for our test to simulate a response.
        proptest::prop_assume!(
            packet1.source_protocol().unwrap() != packet2.source_protocol().unwrap()
        );

        let mut table = NatTable::default();

        let mut packets = [(packet1, outside_dst1), (packet2, outside_dst2)];

        // Remember original src_p and dst
        let original_src_p_and_dst = packets
            .clone()
            .map(|(p, _)| (p.source_protocol().unwrap(), p.destination()));

        // Translate out
        let new_src_p_and_dst = packets
            .clone()
            .map(|(p, d)| table.translate_outgoing(&p, d, Instant::now()).unwrap());

        // Pretend we are getting a response.
        for ((p, _), (new_src_p, new_d)) in packets.iter_mut().zip(new_src_p_and_dst) {
            p.set_destination_protocol(new_src_p.value());
            p.set_src(new_d).unwrap();
        }

        // Translate in
        let responses = packets.map(|(p, _)| {
            let res = table.translate_incoming(&p, Instant::now()).unwrap();

            match res {
                TranslateIncomingResult::Ok { proto, src } => (proto, src),
                TranslateIncomingResult::NoNatSession
                | TranslateIncomingResult::ExpiredNatSession
                | TranslateIncomingResult::IcmpError(_) => panic!("Wrong result"),
            }
        });

        assert_eq!(responses, original_src_p_and_dst);
    }

    #[test_strategy::proptest]
    fn outgoing_tcp_rst_removes_nat_mapping(
        #[strategy(tcp_packet(Just(TcpFlags::default())))] req: IpPacket,
        #[strategy(tcp_packet(Just(TcpFlags { rst: true })))] mut rst: IpPacket,
        #[strategy(any::<IpAddr>())] outside_dst: IpAddr,
    ) {
        let _guard = logging::test("trace");

        proptest::prop_assume!(req.destination().is_ipv4() == outside_dst.is_ipv4()); // Required for our test to simulate a response.
        proptest::prop_assume!(rst.destination().is_ipv4() == outside_dst.is_ipv4()); // Required for our test to simulate a response.
        rst.set_source_protocol(req.source_protocol().unwrap().value());
        rst.set_destination_protocol(req.destination_protocol().unwrap().value());
        rst.set_dst(req.destination()).unwrap();

        let mut table = NatTable::default();
        let mut now = Instant::now();

        let outside = table.translate_outgoing(&req, outside_dst, now).unwrap();

        let mut response = req.clone();
        response.set_destination_protocol(outside.0.value());
        response.set_src(outside.1).unwrap();

        now += Duration::from_secs(1);

        match table.translate_incoming(&response, now).unwrap() {
            TranslateIncomingResult::Ok { .. } => {}
            result @ (TranslateIncomingResult::NoNatSession
            | TranslateIncomingResult::ExpiredNatSession
            | TranslateIncomingResult::IcmpError(_)) => {
                panic!("Wrong result: {result:?}")
            }
        };

        now += Duration::from_secs(1);

        table.translate_outgoing(&rst, outside_dst, now).unwrap();

        now += Duration::from_secs(1);
        table.handle_timeout(now);

        match table.translate_incoming(&response, now).unwrap() {
            TranslateIncomingResult::ExpiredNatSession => {}
            result @ (TranslateIncomingResult::NoNatSession
            | TranslateIncomingResult::Ok { .. }
            | TranslateIncomingResult::IcmpError(_)) => {
                panic!("Wrong result: {result:?}")
            }
        };
    }
}
