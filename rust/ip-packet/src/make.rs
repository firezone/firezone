//! Factory module for making all kinds of packets.

use crate::{IpPacket, MutableIpPacket};
use domain::{
    base::{
        iana::{Class, Opcode, Rcode},
        MessageBuilder, Name, Question, Record, Rtype, ToName, Ttl,
    },
    rdata::AllRecordData,
};
use etherparse::PacketBuilder;
use std::net::{IpAddr, SocketAddr};

/// Helper macro to turn a [`PacketBuilder`] into a [`MutableIpPacket`].
#[macro_export]
macro_rules! build {
    ($packet:expr, $payload:ident) => {{
        let size = $packet.size($payload.len());
        let mut buf = vec![0u8; size + 20];

        $packet
            .write(&mut std::io::Cursor::new(&mut buf[20..]), &$payload)
            .expect("Buffer should be big enough");

        MutableIpPacket::owned(buf).expect("Should be a valid IP packet")
    }};
}

pub fn icmp_request_packet(
    src: IpAddr,
    dst: impl Into<IpAddr>,
    seq: u16,
    identifier: u16,
    payload: &[u8],
) -> Result<MutableIpPacket<'static>, IpVersionMismatch> {
    match (src, dst.into()) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            let packet = PacketBuilder::ipv4(src.octets(), dst.octets(), 64)
                .icmpv4_echo_request(identifier, seq);

            Ok(build!(packet, payload))
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            let packet = PacketBuilder::ipv6(src.octets(), dst.octets(), 64)
                .icmpv6_echo_request(identifier, seq);

            Ok(build!(packet, payload))
        }
        _ => Err(IpVersionMismatch),
    }
}

pub fn icmp_reply_packet(
    src: IpAddr,
    dst: impl Into<IpAddr>,
    seq: u16,
    identifier: u16,
    payload: &[u8],
) -> Result<MutableIpPacket<'static>, IpVersionMismatch> {
    match (src, dst.into()) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            let packet = PacketBuilder::ipv4(src.octets(), dst.octets(), 64)
                .icmpv4_echo_reply(identifier, seq);

            Ok(build!(packet, payload))
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            let packet = PacketBuilder::ipv6(src.octets(), dst.octets(), 64)
                .icmpv6_echo_reply(identifier, seq);

            Ok(build!(packet, payload))
        }
        _ => Err(IpVersionMismatch),
    }
}

pub fn icmp_network_unreachable(
    src: IpAddr,
    dst: IpAddr,
    payload: &[u8],
) -> Result<MutableIpPacket<'static>, IpVersionMismatch> {
    match (src, dst) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            let packet = etherparse::PacketBuilder::ipv4(src.octets(), dst.octets(), 10).icmpv4(
                etherparse::Icmpv4Type::DestinationUnreachable(
                    etherparse::icmpv4::DestUnreachableHeader::Network,
                ),
            );

            let payload = &payload[..12];
            Ok(build!(packet, payload))
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            let packet = etherparse::PacketBuilder::ipv6(src.octets(), dst.octets(), 10).icmpv6(
                etherparse::Icmpv6Type::DestinationUnreachable(
                    etherparse::icmpv6::DestUnreachableCode::NoRoute,
                ),
            );

            let payload = &payload[..24];
            Ok(build!(packet, payload))
        }
        _ => Err(IpVersionMismatch),
    }
}

pub fn tcp_packet<IP>(
    saddr: IP,
    daddr: IP,
    sport: u16,
    dport: u16,
    payload: Vec<u8>,
) -> Result<MutableIpPacket<'static>, IpVersionMismatch>
where
    IP: Into<IpAddr>,
{
    match (saddr.into(), daddr.into()) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            let packet =
                PacketBuilder::ipv4(src.octets(), dst.octets(), 64).tcp(sport, dport, 0, 128);

            Ok(build!(packet, payload))
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            let packet =
                PacketBuilder::ipv6(src.octets(), dst.octets(), 64).tcp(sport, dport, 0, 128);

            Ok(build!(packet, payload))
        }
        _ => Err(IpVersionMismatch),
    }
}

pub fn udp_packet<IP>(
    saddr: IP,
    daddr: IP,
    sport: u16,
    dport: u16,
    payload: Vec<u8>,
) -> Result<MutableIpPacket<'static>, IpVersionMismatch>
where
    IP: Into<IpAddr>,
{
    match (saddr.into(), daddr.into()) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            let packet = PacketBuilder::ipv4(src.octets(), dst.octets(), 64).udp(sport, dport);

            Ok(build!(packet, payload))
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            let packet = PacketBuilder::ipv6(src.octets(), dst.octets(), 64).udp(sport, dport);

            Ok(build!(packet, payload))
        }
        _ => Err(IpVersionMismatch),
    }
}

pub fn dns_query(
    domain: Name<Vec<u8>>,
    kind: Rtype,
    src: SocketAddr,
    dst: SocketAddr,
    id: u16,
) -> Result<MutableIpPacket<'static>, IpVersionMismatch> {
    // Create the DNS query message
    let mut msg_builder = MessageBuilder::new_vec();

    msg_builder.header_mut().set_opcode(Opcode::QUERY);
    msg_builder.header_mut().set_rd(true);
    msg_builder.header_mut().set_id(id);

    // Create the query
    let mut question_builder = msg_builder.question();
    question_builder
        .push(Question::new_in(domain, kind))
        .unwrap();

    let payload = question_builder.finish();

    udp_packet(src.ip(), dst.ip(), src.port(), dst.port(), payload)
}

/// Makes a DNS response to the given DNS query packet, using a resolver callback.
pub fn dns_ok_response<I>(
    packet: IpPacket<'static>,
    resolve: impl Fn(&Name<Vec<u8>>) -> I,
) -> MutableIpPacket<'static>
where
    I: Iterator<Item = IpAddr>,
{
    let udp = packet.unwrap_as_udp();
    let query = packet.unwrap_as_dns();

    let response = MessageBuilder::new_vec();
    let mut answers = response.start_answer(&query, Rcode::NOERROR).unwrap();

    for query in query.question() {
        let query = query.unwrap();
        let name = query.qname().to_name();

        let records = resolve(&name)
            .filter(|ip| {
                #[allow(clippy::wildcard_enum_match_arm)]
                match query.qtype() {
                    Rtype::A => ip.is_ipv4(),
                    Rtype::AAAA => ip.is_ipv6(),
                    _ => todo!(),
                }
            })
            .map(|ip| match ip {
                IpAddr::V4(v4) => AllRecordData::<Vec<_>, Name<Vec<_>>>::A(v4.into()),
                IpAddr::V6(v6) => AllRecordData::<Vec<_>, Name<Vec<_>>>::Aaaa(v6.into()),
            })
            .map(|rdata| Record::new(name.clone(), Class::IN, Ttl::from_days(1), rdata));

        for record in records {
            answers.push(record).unwrap();
        }
    }

    let payload = answers.finish();

    udp_packet(
        packet.destination(),
        packet.source(),
        udp.get_destination(),
        udp.get_source(),
        payload,
    )
    .expect("src and dst are retrieved from the same packet")
}

#[derive(thiserror::Error, Debug)]
#[error("IPs must be of the same version")]
pub struct IpVersionMismatch;
