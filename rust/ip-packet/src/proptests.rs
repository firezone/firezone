use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use pnet_packet::Packet;
use proptest::arbitrary::any;
use proptest::prop_oneof;
use proptest::strategy::Strategy;

use crate::make::{icmp4_packet_with_options, icmp_packet, tcp_packet, udp_packet, IcmpKind};
use crate::MutableIpPacket;

fn tcp_packet_v4() -> impl Strategy<Value = MutableIpPacket<'static>> {
    (
        any::<Ipv4Addr>(),
        any::<Ipv4Addr>(),
        any::<u16>(),
        any::<u16>(),
        any::<Vec<u8>>(),
    )
        .prop_map(|(src, dst, sport, dport, payload)| tcp_packet(src, dst, sport, dport, payload))
}

fn tcp_packet_v6() -> impl Strategy<Value = MutableIpPacket<'static>> {
    (
        any::<Ipv6Addr>(),
        any::<Ipv6Addr>(),
        any::<u16>(),
        any::<u16>(),
        any::<Vec<u8>>(),
    )
        .prop_map(|(src, dst, sport, dport, payload)| tcp_packet(src, dst, sport, dport, payload))
}

fn udp_packet_v4() -> impl Strategy<Value = MutableIpPacket<'static>> {
    (
        any::<Ipv4Addr>(),
        any::<Ipv4Addr>(),
        any::<u16>(),
        any::<u16>(),
        any::<Vec<u8>>(),
    )
        .prop_map(|(src, dst, sport, dport, payload)| udp_packet(src, dst, sport, dport, payload))
}

fn udp_packet_v6() -> impl Strategy<Value = MutableIpPacket<'static>> {
    (
        any::<Ipv6Addr>(),
        any::<Ipv6Addr>(),
        any::<u16>(),
        any::<u16>(),
        any::<Vec<u8>>(),
    )
        .prop_map(|(src, dst, sport, dport, payload)| udp_packet(src, dst, sport, dport, payload))
}

fn icmp_packet_v4() -> impl Strategy<Value = MutableIpPacket<'static>> {
    (
        any::<Ipv4Addr>(),
        any::<Ipv4Addr>(),
        any::<u16>(),
        any::<u16>(),
        any::<IcmpKind>(),
    )
        .prop_map(|(src, dst, id, seq, kind)| icmp_packet(src.into(), dst.into(), id, seq, kind))
}

fn icmp_packet_v4_header_options() -> impl Strategy<Value = MutableIpPacket<'static>> {
    (
        any::<Ipv4Addr>(),
        any::<Ipv4Addr>(),
        any::<u16>(),
        any::<u16>(),
        any::<IcmpKind>(),
        (5u8..15),
    )
        .prop_map(|(src, dst, id, seq, kind, header_length)| {
            icmp4_packet_with_options(src, dst, id, seq, kind, header_length)
        })
}

fn icmp_packet_v6() -> impl Strategy<Value = MutableIpPacket<'static>> {
    (
        any::<Ipv6Addr>(),
        any::<Ipv6Addr>(),
        any::<u16>(),
        any::<u16>(),
        any::<IcmpKind>(),
    )
        .prop_map(|(src, dst, id, seq, kind)| icmp_packet(src.into(), dst.into(), id, seq, kind))
}

fn packet() -> impl Strategy<Value = MutableIpPacket<'static>> {
    prop_oneof![
        tcp_packet_v4(),
        tcp_packet_v6(),
        udp_packet_v4(),
        udp_packet_v6(),
        icmp_packet_v4(),
        icmp_packet_v6(),
    ]
}

#[test_strategy::proptest()]
fn can_translate_dst_packet_back_and_forth(
    #[strategy(packet())] packet: MutableIpPacket<'static>,
    #[strategy(any::<Ipv4Addr>())] src_v4: Ipv4Addr,
    #[strategy(any::<Ipv6Addr>())] src_v6: Ipv6Addr,
    #[strategy(any::<IpAddr>())] dst: IpAddr,
) {
    let original_source = packet.source();
    let original_destination = packet.destination();
    let original_packet = packet.packet().to_vec();

    let original_source_v4 = if let IpAddr::V4(v4) = original_source {
        v4
    } else {
        Ipv4Addr::UNSPECIFIED
    };
    let original_source_v6 = if let IpAddr::V6(v6) = original_source {
        v6
    } else {
        Ipv6Addr::UNSPECIFIED
    };

    let packet = packet.translate_destination(src_v4, src_v6, dst).unwrap();

    assert!(packet.source() == IpAddr::from(src_v4) || packet.source() == IpAddr::from(src_v6) || packet.source() == original_source, "either the translated packet was set to one of the sources or it wasn't translated and it kept the old source");
    assert_eq!(packet.destination(), dst);

    let mut packet = packet
        .translate_destination(original_source_v4, original_source_v6, original_destination)
        .unwrap();
    packet.update_checksum();

    assert_eq!(packet.packet(), original_packet);
}

#[test_strategy::proptest()]
fn can_translate_src_packet_back_and_forth(
    #[strategy(packet())] packet: MutableIpPacket<'static>,
    #[strategy(any::<Ipv4Addr>())] dst_v4: Ipv4Addr,
    #[strategy(any::<Ipv6Addr>())] dst_v6: Ipv6Addr,
    #[strategy(any::<IpAddr>())] src: IpAddr,
) {
    let original_source = packet.source();
    let original_destination = packet.destination();
    let original_packet = packet.packet().to_vec();

    let original_destination_v4 = if let IpAddr::V4(v4) = original_destination {
        v4
    } else {
        Ipv4Addr::UNSPECIFIED
    };
    let original_destination_v6 = if let IpAddr::V6(v6) = original_destination {
        v6
    } else {
        Ipv6Addr::UNSPECIFIED
    };

    let packet = packet.translate_source(dst_v4, dst_v6, src).unwrap();

    assert!(packet.destination() == IpAddr::from(dst_v4) || packet.destination() == IpAddr::from(dst_v6) || packet.destination() == original_destination, "either the translated packet was set to one of the destinations or it wasn't translated and it kept the old destination");
    assert_eq!(packet.source(), src);

    let mut packet = packet
        .translate_source(
            original_destination_v4,
            original_destination_v6,
            original_source,
        )
        .unwrap();
    packet.update_checksum();

    assert_eq!(packet.packet(), original_packet);
}

#[test_strategy::proptest()]
fn can_translate_dst_packet_with_options(
    #[strategy(icmp_packet_v4_header_options())] packet: MutableIpPacket<'static>,
    #[strategy(any::<Ipv4Addr>())] src_v4: Ipv4Addr,
    #[strategy(any::<Ipv6Addr>())] src_v6: Ipv6Addr,
    #[strategy(any::<IpAddr>())] dst: IpAddr,
) {
    let source_protocol = packet.to_immutable().source_protocol().unwrap();
    let destination_protocol = packet.to_immutable().destination_protocol().unwrap();
    let source = packet.source();
    let sequence = packet.to_immutable().as_icmp().and_then(|i| i.sequence());
    let identifier = packet.to_immutable().as_icmp().and_then(|i| i.identifier());

    let packet = packet.translate_destination(src_v4, src_v6, dst).unwrap();
    let packet = packet.to_immutable().to_owned();
    let icmp = packet.as_icmp().unwrap();

    assert!(packet.source() == IpAddr::from(src_v4) || packet.source() == IpAddr::from(src_v6) || packet.source() == source, "either the translated packet was set to one of the sources or it wasn't translated and it kept the old source");
    assert_eq!(packet.destination(), dst);
    assert_eq!(source_protocol, packet.source_protocol().unwrap());
    assert_eq!(destination_protocol, packet.destination_protocol().unwrap());

    assert_eq!(sequence, icmp.sequence());
    assert_eq!(identifier, icmp.identifier());
}
#[test_strategy::proptest()]
fn can_translate_src_packet_with_options(
    #[strategy(icmp_packet_v4_header_options())] packet: MutableIpPacket<'static>,
    #[strategy(any::<Ipv4Addr>())] dst_v4: Ipv4Addr,
    #[strategy(any::<Ipv6Addr>())] dst_v6: Ipv6Addr,
    #[strategy(any::<IpAddr>())] src: IpAddr,
) {
    let source_protocol = packet.to_immutable().source_protocol().unwrap();
    let destination_protocol = packet.to_immutable().destination_protocol().unwrap();
    let destination = packet.destination();
    let sequence = packet.to_immutable().as_icmp().and_then(|i| i.sequence());
    let identifier = packet.to_immutable().as_icmp().and_then(|i| i.identifier());

    let packet = packet.translate_source(dst_v4, dst_v6, src).unwrap();
    let packet = packet.to_immutable().to_owned();
    let icmp = packet.as_icmp().unwrap();

    assert!(packet.destination() == IpAddr::from(dst_v4) || packet.destination() == IpAddr::from(dst_v6) || packet.destination() == destination, "either the translated packet was set to one of the destinations or it wasn't translated and it kept the old destination");
    assert_eq!(packet.source(), src);
    assert_eq!(source_protocol, packet.source_protocol().unwrap());
    assert_eq!(destination_protocol, packet.destination_protocol().unwrap());

    assert_eq!(sequence, icmp.sequence());
    assert_eq!(identifier, icmp.identifier());
}
