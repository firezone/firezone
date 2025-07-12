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
    pub(crate) table: BiMap<(Protocol, IpAddr), (Protocol, IpAddr)>,
    pub(crate) last_seen: BTreeMap<(Protocol, IpAddr), Instant>,

    // We don't bother with proactively freeing this because a single entry is only ~20 bytes and it gets cleanup once the connection to the client goes away.
    expired: HashSet<(Protocol, IpAddr)>,
}

pub(crate) const TCP_TTL: Duration = Duration::from_secs(60 * 60 * 2);
pub(crate) const UDP_TTL: Duration = Duration::from_secs(60 * 2);
pub(crate) const ICMP_TTL: Duration = Duration::from_secs(60 * 2);

impl NatTable {
    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        for (outside, e) in self.last_seen.iter() {
            let ttl = match outside.0 {
                Protocol::Tcp(_) => TCP_TTL,
                Protocol::Udp(_) => UDP_TTL,
                Protocol::Icmp(_) => ICMP_TTL,
            };

            if now.duration_since(*e) >= ttl
                && let Some((inside, _)) = self.table.remove_by_right(outside)
            {
                tracing::debug!(?inside, ?outside, ?ttl, "NAT session expired");
                self.expired.insert(*outside);
            }
        }
    }

    /// Returns true if the NAT table has any entries with the given "inside" IP address.
    pub(crate) fn has_entry_for_inside(&self, ip: IpAddr) -> bool {
        self.table.left_values().any(|(_, c)| c == &ip)
    }

    pub(crate) fn translate_outgoing(
        &mut self,
        packet: &IpPacket,
        outside_dst: IpAddr,
        now: Instant,
    ) -> Result<(Protocol, IpAddr)> {
        let src = packet.source_protocol()?;
        let dst = packet.destination();

        let inside = (src, dst);

        if let Some(outside) = self.table.get_by_left(&inside).copied() {
            if outside.1 == outside_dst {
                tracing::trace!(?inside, ?outside, "Translating outgoing packet");

                if packet.as_tcp().is_some_and(|tcp| tcp.rst()) {
                    tracing::debug!(
                        ?inside,
                        ?outside,
                        "Witnessed outgoing TCP RST, removing NAT session"
                    );

                    self.table.remove_by_left(&inside);
                    self.expired.insert(outside);
                }

                self.last_seen.insert(outside, now);
                return Ok(outside);
            }

            tracing::trace!(?inside, ?outside, "Outgoing packet for expired translation");
        }

        // Find the first available public port, starting from the port of the to-be-mapped packet.
        // This will re-assign the same port in most cases, even after the mapping expires.
        let outside = (src.value()..=u16::MAX)
            .chain(1..src.value())
            .map(|p| (src.with_value(p), outside_dst))
            .find(|outside| !self.table.contains_right(outside))
            .context("Exhausted NAT")?;

        let inside = (src, dst);

        self.table.insert(inside, outside);
        self.last_seen.insert(outside, now);
        self.expired.remove(&outside);

        tracing::debug!(?inside, ?outside, "New NAT session");

        Ok(outside)
    }

    pub(crate) fn translate_incoming(
        &mut self,
        packet: &IpPacket,
        now: Instant,
    ) -> Result<TranslateIncomingResult> {
        if let Some((failed_packet, icmp_error)) = packet.icmp_error()? {
            let outside = (failed_packet.src_proto(), failed_packet.dst());

            if let Some((inside_proto, inside_dst)) = self.translate_incoming_inner(&outside, now) {
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

        let outside = (packet.destination_protocol()?, packet.source());

        if let Some(inside) = self.translate_incoming_inner(&outside, now) {
            if packet.as_tcp().is_some_and(|tcp| tcp.rst()) {
                tracing::debug!(
                    ?inside,
                    ?outside,
                    "Witnessed incoming TCP RST, removing NAT session"
                );

                self.table.remove_by_right(&outside);
                self.expired.insert(outside);
            }

            let (proto, src) = inside;

            return Ok(TranslateIncomingResult::Ok { proto, src });
        }

        if self.expired.contains(&outside) {
            return Ok(TranslateIncomingResult::ExpiredNatSession);
        }

        Ok(TranslateIncomingResult::NoNatSession)
    }

    fn translate_incoming_inner(
        &mut self,
        outside: &(Protocol, IpAddr),
        now: Instant,
    ) -> Option<(Protocol, IpAddr)> {
        let inside = self.table.get_by_right(outside)?;

        tracing::trace!(?inside, ?outside, "Translating incoming packet");
        self.last_seen.insert(*inside, now);

        Some(*inside)
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

        let sent_at = Instant::now();
        let mut table = NatTable::default();
        let response_delay = Duration::from_secs(response_delay);

        // Remember original src_p and dst
        let src = packet.source_protocol().unwrap();
        let dst = packet.destination();

        // Translate out
        let (new_source_protocol, new_dst_ip) = table
            .translate_outgoing(&packet, outside_dst, sent_at)
            .unwrap();

        // Pretend we are getting a response.
        let mut response = packet.clone();
        response.set_destination_protocol(new_source_protocol.value());
        response.set_src(new_dst_ip).unwrap();

        // Update time.
        table.handle_timeout(sent_at + response_delay);

        // Translate in
        let translate_incoming = table
            .translate_incoming(&response, sent_at + response_delay)
            .unwrap();

        let ttl = match src {
            Protocol::Tcp(_) => 7200,
            Protocol::Udp(_) => 120,
            Protocol::Icmp(_) => 120,
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
        let _guard = firezone_logging::test("trace");

        proptest::prop_assume!(req.destination().is_ipv4() == outside_dst.is_ipv4()); // Required for our test to simulate a response.
        proptest::prop_assume!(rst.destination().is_ipv4() == outside_dst.is_ipv4()); // Required for our test to simulate a response.
        rst.set_source_protocol(req.source_protocol().unwrap().value());
        rst.set_destination_protocol(req.destination_protocol().unwrap().value());
        rst.set_dst(req.destination()).unwrap();

        let mut table = NatTable::default();

        let outside = table
            .translate_outgoing(&req, outside_dst, Instant::now())
            .unwrap();

        let mut response = req.clone();
        response.set_destination_protocol(outside.0.value());
        response.set_src(outside.1).unwrap();

        match table.translate_incoming(&response, Instant::now()).unwrap() {
            TranslateIncomingResult::Ok { .. } => {}
            result @ (TranslateIncomingResult::NoNatSession
            | TranslateIncomingResult::ExpiredNatSession
            | TranslateIncomingResult::IcmpError(_)) => {
                panic!("Wrong result: {result:?}")
            }
        };

        table
            .translate_outgoing(&rst, outside_dst, Instant::now())
            .unwrap();

        match table.translate_incoming(&response, Instant::now()).unwrap() {
            TranslateIncomingResult::ExpiredNatSession => {}
            result @ (TranslateIncomingResult::NoNatSession
            | TranslateIncomingResult::Ok { .. }
            | TranslateIncomingResult::IcmpError(_)) => {
                panic!("Wrong result: {result:?}")
            }
        };
    }
}
