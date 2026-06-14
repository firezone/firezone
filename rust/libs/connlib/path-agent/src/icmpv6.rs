//! Path-probe packet shape. Probes ride the WG envelope as ICMPv6
//! echo to/from magic addresses in the `100::/64` discard prefix
//! (RFC 6666) and are intercepted after `Tunn::decapsulate_at`.

use std::net::{IpAddr, Ipv6Addr};

use ip_packet::{Icmpv6Type, IpPacket};

/// `dead:1ce` — "ICE is dead", iceless's calling card. Exposed so
/// callers can filter probes off the wire by address match.
pub const PROBE_SRC: Ipv6Addr = Ipv6Addr::new(0x0100, 0, 0, 0, 0, 0xdead, 0x01ce, 0x0001);
pub const PROBE_DST: Ipv6Addr = Ipv6Addr::new(0x0100, 0, 0, 0, 0, 0xdead, 0x01ce, 0x0002);

/// Whether a packet is an Echo Request or an Echo Reply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Echo {
    Request,
    Reply,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Probe {
    pub kind: Echo,
    pub id: u16,
    pub seq: u16,
}

impl Probe {
    /// `Some` iff `packet` is an ICMPv6 echo between the magic addresses.
    pub(crate) fn try_parse(packet: &IpPacket) -> Option<Self> {
        if packet.source() != IpAddr::V6(PROBE_SRC) || packet.destination() != IpAddr::V6(PROBE_DST)
        {
            return None;
        }

        let icmp = packet.as_icmpv6()?;
        let (kind, header) = match icmp.icmp_type() {
            Icmpv6Type::EchoRequest(h) => (Echo::Request, h),
            Icmpv6Type::EchoReply(h) => (Echo::Reply, h),
            _ => return None,
        };

        Some(Self {
            kind,
            id: header.id,
            seq: header.seq,
        })
    }
}

pub(crate) fn build_echo_request(id: u16, seq: u16) -> IpPacket {
    ip_packet::make::icmp_request_packet(IpAddr::V6(PROBE_SRC), IpAddr::V6(PROBE_DST), seq, id, &[])
        .expect("magic addresses and empty payload always fit")
}

pub(crate) fn build_echo_reply(id: u16, seq: u16) -> IpPacket {
    ip_packet::make::icmp_reply_packet(IpAddr::V6(PROBE_SRC), IpAddr::V6(PROBE_DST), seq, id, &[])
        .expect("magic addresses and empty payload always fit")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_echo_request() {
        let packet = build_echo_request(0x1234, 0x5678);
        let probe = Probe::try_parse(&packet).expect("parses");
        assert_eq!(probe.kind, Echo::Request);
        assert_eq!(probe.id, 0x1234);
        assert_eq!(probe.seq, 0x5678);
    }

    #[test]
    fn round_trip_echo_reply() {
        let packet = build_echo_reply(0x0001, 0xffff);
        let probe = Probe::try_parse(&packet).expect("parses");
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
        assert!(Probe::try_parse(&packet).is_none());
    }

    #[test]
    fn parse_rejects_non_icmpv6() {
        let packet = ip_packet::make::udp_packet(PROBE_SRC, PROBE_DST, 1, 2, &[]).unwrap();
        assert!(Probe::try_parse(&packet).is_none());
    }

    #[test]
    fn id_and_seq_are_preserved_through_full_range() {
        for id in [0u16, 1, 0x7fff, 0x8000, 0xffff] {
            for seq in [0u16, 0xaa55, 0xffff] {
                let packet = build_echo_request(id, seq);
                let probe = Probe::try_parse(&packet).expect("parses");
                assert_eq!(probe.id, id, "id roundtrip");
                assert_eq!(probe.seq, seq, "seq roundtrip");
            }
        }
    }
}
