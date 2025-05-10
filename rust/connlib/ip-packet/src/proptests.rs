use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use proptest::arbitrary::any;
use proptest::prop_oneof;
use proptest::strategy::Strategy;

use crate::{IpPacket, build};
use etherparse::{Ipv4Extensions, Ipv4Header, Ipv4Options, PacketBuilder};
use proptest::prelude::Just;

const EMPTY_PAYLOAD: &[u8] = &[];

fn tcp_packet_v4() -> impl Strategy<Value = IpPacket> {
    (
        any::<Ipv4Addr>(),
        any::<Ipv4Addr>(),
        any::<u16>(),
        any::<u16>(),
        any::<Vec<u8>>(),
    )
        .prop_map(|(src, dst, sport, dport, payload)| {
            build!(
                PacketBuilder::ipv4(src.octets(), dst.octets(), 64).tcp(sport, dport, 0, 128),
                payload
            )
        })
        .prop_map(|r: anyhow::Result<IpPacket>| r.unwrap())
}

fn tcp_packet_v6() -> impl Strategy<Value = IpPacket> {
    (
        any::<Ipv6Addr>(),
        any::<Ipv6Addr>(),
        any::<u16>(),
        any::<u16>(),
        any::<Vec<u8>>(),
    )
        .prop_map(|(src, dst, sport, dport, payload)| {
            build!(
                PacketBuilder::ipv6(src.octets(), dst.octets(), 64).tcp(sport, dport, 0, 128),
                payload
            )
        })
        .prop_map(|r: anyhow::Result<IpPacket>| r.unwrap())
}

fn udp_packet_v4() -> impl Strategy<Value = IpPacket> {
    (
        any::<Ipv4Addr>(),
        any::<Ipv4Addr>(),
        any::<u16>(),
        any::<u16>(),
        any::<Vec<u8>>(),
    )
        .prop_map(|(src, dst, sport, dport, payload)| {
            build!(
                PacketBuilder::ipv4(src.octets(), dst.octets(), 64).udp(sport, dport),
                payload
            )
        })
        .prop_map(|r: anyhow::Result<IpPacket>| r.unwrap())
}

fn udp_packet_v6() -> impl Strategy<Value = IpPacket> {
    (
        any::<Ipv6Addr>(),
        any::<Ipv6Addr>(),
        any::<u16>(),
        any::<u16>(),
        any::<Vec<u8>>(),
    )
        .prop_map(|(src, dst, sport, dport, payload)| {
            build!(
                PacketBuilder::ipv6(src.octets(), dst.octets(), 64).udp(sport, dport),
                payload
            )
        })
        .prop_map(|r: anyhow::Result<IpPacket>| r.unwrap())
}

fn icmp_request_packet_v4() -> impl Strategy<Value = IpPacket> {
    (
        any::<Ipv4Addr>(),
        any::<Ipv4Addr>(),
        any::<u16>(),
        any::<u16>(),
        ipv4_options(),
    )
        .prop_map(|(src, dst, id, seq, options)| {
            let packet = PacketBuilder::ip(etherparse::IpHeaders::Ipv4(
                Ipv4Header {
                    source: src.octets(),
                    destination: dst.octets(),
                    options,
                    ..Default::default()
                },
                Ipv4Extensions::default(),
            ))
            .icmpv4_echo_request(id, seq);

            build!(packet, EMPTY_PAYLOAD)
        })
        .prop_map(|r: anyhow::Result<IpPacket>| r.unwrap())
}

fn icmp_reply_packet_v4() -> impl Strategy<Value = IpPacket> {
    (
        any::<Ipv4Addr>(),
        any::<Ipv4Addr>(),
        any::<u16>(),
        any::<u16>(),
        ipv4_options(),
    )
        .prop_map(|(src, dst, id, seq, options)| {
            let packet = PacketBuilder::ip(etherparse::IpHeaders::Ipv4(
                Ipv4Header {
                    source: src.octets(),
                    destination: dst.octets(),
                    options,
                    ..Default::default()
                },
                Ipv4Extensions::default(),
            ))
            .icmpv4_echo_reply(id, seq);

            build!(packet, EMPTY_PAYLOAD)
        })
        .prop_map(|r: anyhow::Result<IpPacket>| r.unwrap())
}

fn icmp_request_packet_v6() -> impl Strategy<Value = IpPacket> {
    (
        any::<Ipv6Addr>(),
        any::<Ipv6Addr>(),
        any::<u16>(),
        any::<u16>(),
    )
        .prop_map(|(src, dst, id, seq)| {
            build!(
                PacketBuilder::ipv6(src.octets(), dst.octets(), 64).icmpv6_echo_request(id, seq),
                EMPTY_PAYLOAD
            )
        })
        .prop_map(|r: anyhow::Result<IpPacket>| r.unwrap())
}

fn icmp_reply_packet_v6() -> impl Strategy<Value = IpPacket> {
    (
        any::<Ipv6Addr>(),
        any::<Ipv6Addr>(),
        any::<u16>(),
        any::<u16>(),
    )
        .prop_map(|(src, dst, id, seq)| {
            build!(
                PacketBuilder::ipv6(src.octets(), dst.octets(), 64).icmpv6_echo_reply(id, seq),
                EMPTY_PAYLOAD
            )
        })
        .prop_map(|r: anyhow::Result<IpPacket>| r.unwrap())
}

fn ipv4_options() -> impl Strategy<Value = Ipv4Options> {
    prop_oneof![
        Just(Ipv4Options::from([0u8; 0])),
        Just(Ipv4Options::from([0u8; 4])),
        Just(Ipv4Options::from([0u8; 8])),
        Just(Ipv4Options::from([0u8; 12])),
        Just(Ipv4Options::from([0u8; 16])),
        Just(Ipv4Options::from([0u8; 20])),
        Just(Ipv4Options::from([0u8; 24])),
        Just(Ipv4Options::from([0u8; 28])),
        Just(Ipv4Options::from([0u8; 32])),
        Just(Ipv4Options::from([0u8; 36])),
        Just(Ipv4Options::from([0u8; 40])),
    ]
}

fn packet_v4() -> impl Strategy<Value = IpPacket> {
    prop_oneof![
        tcp_packet_v4(),
        udp_packet_v4(),
        icmp_request_packet_v4(),
        icmp_reply_packet_v4(),
    ]
}

fn packet_v6() -> impl Strategy<Value = IpPacket> {
    prop_oneof![
        tcp_packet_v6(),
        udp_packet_v6(),
        icmp_request_packet_v6(),
        icmp_reply_packet_v6(),
    ]
}

#[test_strategy::proptest()]
fn nat_6446(
    #[strategy(packet_v6())] packet_v6: IpPacket,
    #[strategy(any::<Ipv4Addr>())] new_src: Ipv4Addr,
    #[strategy(any::<Ipv4Addr>())] new_dst: Ipv4Addr,
) {
    let header = packet_v6.ipv6_header().unwrap();
    let payload = packet_v6.payload().to_vec();

    let packet_v4 = packet_v6.consume_to_ipv4(new_src, new_dst).unwrap();

    assert_eq!(packet_v4.source(), IpAddr::V4(new_src));
    assert_eq!(packet_v4.destination(), new_dst);

    let mut new_packet_v6 = packet_v4
        .consume_to_ipv6(header.source_addr(), header.destination_addr())
        .unwrap();
    new_packet_v6.update_checksum();

    assert_eq!(new_packet_v6.ipv6_header().unwrap(), header);
    assert_eq!(new_packet_v6.payload(), payload);
}

#[test_strategy::proptest()]
fn nat_4664(
    #[strategy(packet_v4())] packet_v4: IpPacket,
    #[strategy(any::<Ipv6Addr>())] new_src: Ipv6Addr,
    #[strategy(any::<Ipv6Addr>())] new_dst: Ipv6Addr,
) {
    let header = packet_v4.ipv4_header().unwrap();
    let payload = packet_v4.payload().to_vec();

    let packet_v6 = packet_v4.consume_to_ipv6(new_src, new_dst).unwrap();

    assert_eq!(packet_v6.source(), IpAddr::V6(new_src));
    assert_eq!(packet_v6.destination(), new_dst);

    let mut new_packet_v4 = packet_v6
        .consume_to_ipv4(header.source.into(), header.destination.into())
        .unwrap();
    new_packet_v4.update_checksum();

    let mut header_without_options = Ipv4Header {
        options: Ipv4Options::default(), // IPv4 options are lost in translation.
        total_len: header.total_len - header.options.len_u8() as u16,
        ..header
    };
    header_without_options.header_checksum = header_without_options.calc_header_checksum();

    assert_eq!(new_packet_v4.ipv4_header().unwrap(), header_without_options);
    assert_eq!(new_packet_v4.payload(), payload);
}
