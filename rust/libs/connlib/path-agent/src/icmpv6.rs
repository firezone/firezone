//! Borrowed packet shape for path probes.
//!
//! Iceless connections measure round-trip time and confirm path
//! reachability with packets shaped as ICMPv6 Echo Request/Reply, but
//! these never touch any IP stack — they live entirely inside snownet,
//! travelling through `Tunn::encapsulate` like ordinary user traffic and
//! being intercepted on the receive side before they reach the tun
//! device. The ICMPv6 envelope is just a packet shape we're reusing so
//! we don't have to design our own (its `id`/`seq` fields are convenient
//! for matching probes to replies).
//!
//! Source and destination addresses come from the IPv6 discard prefix
//! `100::/64` (RFC 6666) so they cannot collide with anything a user
//! might route. Inbound packets only count as path probes when *both*
//! addresses match — the chance of ordinary user traffic accidentally
//! tripping that check is negligible.

// The probe loop in subsequent commits is the first user of these helpers.
#![allow(dead_code)]

use std::net::{IpAddr, Ipv6Addr};

use ip_packet::{Icmpv6Type, IpPacket};

/// Source address of every probe packet PathAgent emits.
pub(crate) const PROBE_SRC: Ipv6Addr = Ipv6Addr::new(0x0100, 0, 0, 0, 0, 0xfeed, 0xface, 0x0001);

/// Destination address of every probe packet PathAgent emits.
pub(crate) const PROBE_DST: Ipv6Addr = Ipv6Addr::new(0x0100, 0, 0, 0, 0, 0xfeed, 0xface, 0x0002);

/// Whether a packet is an Echo Request or an Echo Reply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Echo {
    Request,
    Reply,
}

/// Parsed view of a probe packet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Probe {
    pub kind: Echo,
    pub id: u16,
    pub seq: u16,
}

/// Build an outbound IPv6+ICMPv6 Echo Request between the magic
/// addresses, with the given `id` / `seq`. The result is fed straight
/// into `Tunn::encapsulate` like an ordinary user IP packet.
pub(crate) fn build_echo_request(id: u16, seq: u16) -> IpPacket {
    ip_packet::make::icmp_request_packet(IpAddr::V6(PROBE_SRC), IpAddr::V6(PROBE_DST), seq, id, &[])
        .expect("magic addresses and empty payload always fit")
}

/// Build an outbound IPv6+ICMPv6 Echo Reply matching a previously
/// received Request.
pub(crate) fn build_echo_reply(id: u16, seq: u16) -> IpPacket {
    ip_packet::make::icmp_reply_packet(IpAddr::V6(PROBE_SRC), IpAddr::V6(PROBE_DST), seq, id, &[])
        .expect("magic addresses and empty payload always fit")
}

/// Try to interpret `packet` as one of our path probes. Returns `Some`
/// only when the IP source / destination match the magic discard-prefix
/// addresses and the ICMPv6 type is Echo Request or Reply.
pub(crate) fn try_parse(packet: &IpPacket) -> Option<Probe> {
    if packet.source() != IpAddr::V6(PROBE_SRC) || packet.destination() != IpAddr::V6(PROBE_DST) {
        return None;
    }

    let icmp = packet.as_icmpv6()?;
    let (kind, header) = match icmp.icmp_type() {
        Icmpv6Type::EchoRequest(h) => (Echo::Request, h),
        Icmpv6Type::EchoReply(h) => (Echo::Reply, h),
        _ => return None,
    };

    Some(Probe {
        kind,
        id: header.id,
        seq: header.seq,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_echo_request() {
        let packet = build_echo_request(0x1234, 0x5678);
        let probe = try_parse(&packet).expect("parses");
        assert_eq!(probe.kind, Echo::Request);
        assert_eq!(probe.id, 0x1234);
        assert_eq!(probe.seq, 0x5678);
    }

    #[test]
    fn round_trip_echo_reply() {
        let packet = build_echo_reply(0x0001, 0xffff);
        let probe = try_parse(&packet).expect("parses");
        assert_eq!(probe.kind, Echo::Reply);
        assert_eq!(probe.id, 0x0001);
        assert_eq!(probe.seq, 0xffff);
    }

    #[test]
    fn parse_rejects_wrong_addresses() {
        let packet = ip_packet::make::icmp_request_packet(
            IpAddr::V6(Ipv6Addr::LOCALHOST),
            IpAddr::V6(PROBE_DST),
            0,
            0,
            &[],
        )
        .unwrap();
        assert!(try_parse(&packet).is_none());
    }

    #[test]
    fn parse_rejects_non_icmpv6() {
        let packet = ip_packet::make::udp_packet(PROBE_SRC, PROBE_DST, 1, 2, &[]).unwrap();
        assert!(try_parse(&packet).is_none());
    }

    #[test]
    fn id_and_seq_are_preserved_through_full_range() {
        for id in [0u16, 1, 0x7fff, 0x8000, 0xffff] {
            for seq in [0u16, 0xaa55, 0xffff] {
                let packet = build_echo_request(id, seq);
                let probe = try_parse(&packet).expect("parses");
                assert_eq!(probe.id, id, "id roundtrip");
                assert_eq!(probe.seq, seq, "seq roundtrip");
            }
        }
    }
}
