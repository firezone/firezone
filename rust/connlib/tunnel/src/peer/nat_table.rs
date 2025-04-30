//! A stateful symmetric NAT table that performs conversion between a client's picked proxy ip and the actual resource's IP.
use anyhow::{Context, Result};
use bimap::BiMap;
use ip_packet::{DestUnreachable, FailedPacket, IpPacket, PacketBuilder, Protocol};
use std::collections::{BTreeMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::time::{Duration, Instant};

/// The stateful NAT table converts a client's picked proxy ip for a domain name into the real IP for that IP
/// it also picks a source port to keep track of the original proxy IP used.
/// The NAT sessions, i.e. the mapping between (source_port, proxy_ip) to (source_port', real_ip) is kept for 60 seconds
/// after no incoming traffic is received.
///
/// Note that for ICMP echo/reply the identity number is used as a stand in for the source port.
///
/// Also, the proxy_ip and the real_ip version may not coincide, in that case a translation mechanism must be used (RFC6145)
///
/// This nat table doesn't perform any mangling just provides the converted port/ip for upper layers
#[derive(Default, Debug)]
pub(crate) struct NatTable {
    pub(crate) table: BiMap<(Protocol, IpAddr), (Protocol, IpAddr)>,
    pub(crate) last_seen: BTreeMap<(Protocol, IpAddr), Instant>,

    // We don't bother with proactively freeing this because a single entry is only ~20 bytes and it gets cleanup once the connection to the client goes away.
    expired: HashSet<(Protocol, IpAddr)>,
}

pub(crate) const TTL: Duration = Duration::from_secs(60);

impl NatTable {
    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        for (outside, e) in self.last_seen.iter() {
            if now.duration_since(*e) >= TTL {
                if let Some((inside, _)) = self.table.remove_by_right(outside) {
                    tracing::debug!(?inside, ?outside, "NAT session expired");
                    self.expired.insert(*outside);
                }
            }
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

        let inside = (src, dst);

        if let Some(outside) = self.table.get_by_left(&inside) {
            if outside.1 == outside_dst {
                tracing::trace!(?inside, ?outside, "Translating outgoing packet");

                self.last_seen.insert(*outside, now);
                return Ok(*outside);
            }

            tracing::warn!(
                ?inside,
                ?outside,
                new_outside_ip = %outside_dst,
                "Outgoing packet for expired translation; outside entry will be evicted"
            );
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

        tracing::debug!(?inside, ?outside, "New NAT session");

        Ok(outside)
    }

    pub(crate) fn translate_incoming(
        &mut self,
        packet: &IpPacket,
        now: Instant,
    ) -> Result<TranslateIncomingResult> {
        if let Some((failed_packet, icmp_error)) = packet.icmp_unreachable_destination()? {
            let outside = (failed_packet.src_proto(), failed_packet.dst());

            if let Some((inside_proto, inside_dst)) = self.translate_incoming_inner(&outside, now) {
                return Ok(TranslateIncomingResult::DestinationUnreachable(
                    DestinationUnreachablePrototype {
                        inside_dst,
                        inside_proto,
                        failed_packet,
                        icmp_error,
                    },
                ));
            }

            if self.expired.contains(&outside) {
                return Ok(TranslateIncomingResult::ExpiredNatSession);
            }

            return Ok(TranslateIncomingResult::NoNatSession);
        }

        let outside = (packet.destination_protocol()?, packet.source());

        if let Some((proto, src)) = self.translate_incoming_inner(&outside, now) {
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

/// A prototype for an ICMP "Destination unreachable" packet.
///
/// A packet coming in from the "outside" of the NAT may be an ICMP "Destination unreachable" error.
/// In that case, our regular NAT lookup will fail as that one relies on Layer-4 protocol (TCP/UDP port or ICMP identifier).
///
/// ICMP error messages contain a part of the original IP packet that could not be routed.
/// In order for the NAT to be transparent, the IP and protocol layer within that original packet also need to be translated.
#[derive(Debug, PartialEq, Eq)]
pub struct DestinationUnreachablePrototype {
    /// The "original" destination IP that could not be reached.
    ///
    /// This is a "proxy IP" as generated by the Firezone client during DNS resolution.
    inside_dst: IpAddr,
    inside_proto: Protocol,

    icmp_error: DestUnreachable,

    failed_packet: FailedPacket,
}

impl DestinationUnreachablePrototype {
    /// Turns this prototype into an actual ICMP error IP packet, targeting the given IPv4/IPv6 address, depending on the original Resource address.
    ///
    /// Due to our NAT64/64 implementation, the ICMP error that we receive on the Gateway may not be what we want to forward to the client.
    /// For example, in case we translate a TCP-SYN from IPv4 to IPv6 but the IPv6 address is unreachable, we need to:
    /// - Translate the failed packet embedded in the ICMP error back to an IPv4 packet.
    /// - Send an ICMPv4 error instead of an ICMPv6 error.
    pub fn into_packet(self, dst_v4: Ipv4Addr, dst_v6: Ipv6Addr) -> Result<IpPacket> {
        // First, translate the failed packet as if it would have directly originated from the client (without our NAT applied).
        let original_packet = self
            .failed_packet
            .translate_destination(self.inside_dst, self.inside_proto, dst_v4, dst_v6)
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

    pub fn error(&self) -> &DestUnreachable {
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
    DestinationUnreachable(DestinationUnreachablePrototype),
    ExpiredNatSession,
    NoNatSession,
}

#[cfg(all(test, feature = "proptest"))]
mod tests {
    use super::*;
    use ip_packet::{IpPacket, proptest::*};
    use proptest::prelude::*;

    #[test_strategy::proptest(ProptestConfig { max_local_rejects: 10_000, max_global_rejects: 10_000, ..ProptestConfig::default() })]
    fn translates_back_and_forth_packet(
        #[strategy(udp_or_tcp_or_icmp_packet())] packet: IpPacket,
        #[strategy(any::<IpAddr>())] outside_dst: IpAddr,
        #[strategy(0..120u64)] response_delay: u64,
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
        response.set_src(new_dst_ip);

        // Update time.
        table.handle_timeout(sent_at + response_delay);

        // Translate in
        let translate_incoming = table
            .translate_incoming(&response, sent_at + response_delay)
            .unwrap();

        // Assert
        if response_delay >= Duration::from_secs(60) {
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
            p.set_src(new_d);
        }

        // Translate in
        let responses = packets.map(|(p, _)| {
            let res = table.translate_incoming(&p, Instant::now()).unwrap();

            match res {
                TranslateIncomingResult::Ok { proto, src } => (proto, src),
                TranslateIncomingResult::NoNatSession
                | TranslateIncomingResult::ExpiredNatSession
                | TranslateIncomingResult::DestinationUnreachable(_) => panic!("Wrong result"),
            }
        });

        assert_eq!(responses, original_src_p_and_dst);
    }
}
