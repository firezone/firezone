use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use pnet_packet::Packet;
use proptest::arbitrary::any;
use proptest::strategy::Strategy;

use crate::make::{icmp_reply_packet, icmp_request_packet, tcp_packet, udp_packet};
use crate::MutableIpPacket;

fn non_icmp_packet() -> impl Strategy<Value = MutableIpPacket<'static>> {
    (
        any::<IpAddr>(),
        any::<IpAddr>(),
        any::<u16>(),
        any::<u16>(),
        any::<Vec<u8>>(),
        any::<u8>(),
    )
        .prop_filter("IPs must be of the same version", |(src, dst, ..)| {
            src.is_ipv4() == dst.is_ipv4()
        })
        .prop_map(|(src, dst, sport, dport, payload, proto)|
            // using a bool instead of prop_oneof because we can't wrap mutableippacket in Just because it's non-clonable
            match proto % 4 {
                 0 => tcp_packet(src, dst, sport, dport, payload),
                 1 => udp_packet(src, dst, sport, dport, payload),
                 2 => icmp_request_packet(src, dst, sport, dport),
                 3 => icmp_reply_packet(src, dst, sport, dport),
                 _ => unreachable!()
            })
}

#[test_strategy::proptest()]
fn can_translate_dst_packet(
    #[strategy(non_icmp_packet())] packet: MutableIpPacket<'static>,
    #[strategy(any::<Ipv4Addr>())] src_v4: Ipv4Addr,
    #[strategy(any::<Ipv6Addr>())] src_v6: Ipv6Addr,
    #[strategy(any::<IpAddr>())] dst: IpAddr,
) {
    let source_protocol = packet.to_immutable().source_protocol().unwrap();
    let destination_protocol = packet.to_immutable().destination_protocol().unwrap();
    let payload = packet.payload().to_vec();
    let source = packet.source();
    let sequence = packet.to_immutable().as_icmp().and_then(|i| i.sequence());
    let identifier = packet.to_immutable().as_icmp().and_then(|i| i.identifier());

    let packet = packet.translate_destination(src_v4, src_v6, dst).unwrap();

    assert!(packet.source() == IpAddr::from(src_v4) || packet.source() == IpAddr::from(src_v6) || packet.source() == source, "either the translated packet was set to one of the sources or it wasn't translated and it kept the old source");
    assert_eq!(packet.destination(), dst);
    assert_eq!(
        source_protocol,
        packet.to_immutable().source_protocol().unwrap()
    );
    assert_eq!(
        destination_protocol,
        packet.to_immutable().destination_protocol().unwrap()
    );

    if let Some(icmp) = packet.to_immutable().as_icmp() {
        assert_eq!(sequence, icmp.sequence());
        assert_eq!(identifier, icmp.identifier());
    } else {
        assert_eq!(payload, packet.payload());
        assert!(sequence.is_none());
        assert!(identifier.is_none());
    }
}
#[test_strategy::proptest()]
fn can_translate_src_packet(
    #[strategy(non_icmp_packet())] packet: MutableIpPacket<'static>,
    #[strategy(any::<Ipv4Addr>())] dst_v4: Ipv4Addr,
    #[strategy(any::<Ipv6Addr>())] dst_v6: Ipv6Addr,
    #[strategy(any::<IpAddr>())] src: IpAddr,
) {
    let source_protocol = packet.to_immutable().source_protocol().unwrap();
    let destination_protocol = packet.to_immutable().destination_protocol().unwrap();
    let payload = packet.payload().to_vec();
    let destination = packet.destination();
    let sequence = packet.to_immutable().as_icmp().and_then(|i| i.sequence());
    let identifier = packet.to_immutable().as_icmp().and_then(|i| i.identifier());

    let packet = packet.translate_source(dst_v4, dst_v6, src).unwrap();

    assert!(packet.destination() == IpAddr::from(dst_v4) || packet.destination() == IpAddr::from(dst_v6) || packet.destination() == destination, "either the translated packet was set to one of the destinations or it wasn't translated and it kept the old destination");
    assert_eq!(packet.source(), src);
    assert_eq!(
        source_protocol,
        packet.to_immutable().source_protocol().unwrap()
    );
    assert_eq!(
        destination_protocol,
        packet.to_immutable().destination_protocol().unwrap()
    );

    if let Some(icmp) = packet.to_immutable().as_icmp() {
        assert_eq!(sequence, icmp.sequence());
        assert_eq!(identifier, icmp.identifier());
    } else {
        assert_eq!(payload, packet.payload());
        assert!(sequence.is_none());
        assert!(identifier.is_none());
    }
}
