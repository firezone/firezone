//! Factory module for making all kinds of packets.

use crate::MutableIpPacket;
use hickory_proto::{
    rr::{Name, RecordType},
    serialize::binary::BinEncodable,
};
use pnet_packet::{
    ip::IpNextHeaderProtocol,
    ipv4::MutableIpv4Packet,
    ipv6::MutableIpv6Packet,
    tcp::{self, MutableTcpPacket},
    udp::{self, MutableUdpPacket},
};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

pub fn icmp_request_packet(src: IpAddr, dst: impl Into<IpAddr>) -> MutableIpPacket<'static> {
    icmp_packet(src, dst.into(), 1, 0, IcmpKind::Request)
}

pub fn icmp_response_packet(src: IpAddr, dst: impl Into<IpAddr>) -> MutableIpPacket<'static> {
    icmp_packet(src, dst.into(), 1, 0, IcmpKind::Response)
}

enum IcmpKind {
    Request,
    Response,
}

fn icmp_packet(
    src: IpAddr,
    dst: IpAddr,
    seq: u16,
    identifier: u16,
    kind: IcmpKind,
) -> MutableIpPacket<'static> {
    match (src, dst) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            use crate::{
                icmp::{
                    echo_request::{IcmpCodes, MutableEchoRequestPacket},
                    IcmpTypes, MutableIcmpPacket,
                },
                ip::IpNextHeaderProtocols,
                MutablePacket as _, Packet as _,
            };

            let mut buf = vec![0u8; 60];

            ipv4_header(src, dst, IpNextHeaderProtocols::Icmp, &mut buf[..]);

            let mut icmp_packet = MutableIcmpPacket::new(&mut buf[20..]).unwrap();

            match kind {
                IcmpKind::Request => {
                    icmp_packet.set_icmp_type(IcmpTypes::EchoRequest);
                    icmp_packet.set_icmp_code(IcmpCodes::NoCode);
                }
                IcmpKind::Response => {
                    icmp_packet.set_icmp_type(IcmpTypes::EchoReply);
                    icmp_packet.set_icmp_code(IcmpCodes::NoCode);
                }
            }

            icmp_packet.set_checksum(0);

            let mut echo_request_packet =
                MutableEchoRequestPacket::new(icmp_packet.payload_mut()).unwrap();
            echo_request_packet.set_sequence_number(seq);
            echo_request_packet.set_identifier(identifier);
            echo_request_packet.set_checksum(crate::util::checksum(
                echo_request_packet.to_immutable().packet(),
                2,
            ));

            MutableIpPacket::owned(buf).unwrap()
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            use crate::{
                icmpv6::{
                    echo_request::MutableEchoRequestPacket, Icmpv6Code, Icmpv6Types,
                    MutableIcmpv6Packet,
                },
                ip::IpNextHeaderProtocols,
                MutablePacket as _,
            };

            let mut buf = vec![0u8; 128];

            ipv6_header(src, dst, IpNextHeaderProtocols::Icmpv6, &mut buf);

            let mut icmp_packet = MutableIcmpv6Packet::new(&mut buf[40..]).unwrap();

            match kind {
                IcmpKind::Request => {
                    icmp_packet.set_icmpv6_type(Icmpv6Types::EchoRequest);
                    icmp_packet.set_icmpv6_code(Icmpv6Code::new(0));
                }
                IcmpKind::Response => {
                    icmp_packet.set_icmpv6_type(Icmpv6Types::EchoReply);
                    icmp_packet.set_icmpv6_code(Icmpv6Code::new(0));
                }
            }

            let mut echo_request_packet =
                MutableEchoRequestPacket::new(icmp_packet.payload_mut()).unwrap();
            echo_request_packet.set_identifier(identifier);
            echo_request_packet.set_sequence_number(seq);
            echo_request_packet.set_checksum(0);

            let checksum = crate::icmpv6::checksum(&icmp_packet.to_immutable(), &src, &dst);
            MutableEchoRequestPacket::new(icmp_packet.payload_mut())
                .unwrap()
                .set_checksum(checksum);

            MutableIpPacket::owned(buf).unwrap()
        }
        (IpAddr::V6(_), IpAddr::V4(_)) | (IpAddr::V4(_), IpAddr::V6(_)) => {
            panic!("IPs must be of the same version")
        }
    }
}

pub fn tcp_packet(
    saddr: IpAddr,
    daddr: IpAddr,
    sport: u16,
    dport: u16,
    payload: Vec<u8>,
) -> MutableIpPacket<'static> {
    match (saddr, daddr) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            use crate::ip::IpNextHeaderProtocols;

            let len = 20 + 20 + payload.len();
            let mut buf = vec![0u8; len];

            ipv4_header(src, dst, IpNextHeaderProtocols::Tcp, &mut buf);

            tcp_header(saddr, daddr, sport, dport, &payload, &mut buf[20..]);
            MutableIpPacket::owned(buf).unwrap()
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            use crate::ip::IpNextHeaderProtocols;

            let mut buf = vec![0u8; 40 + 20 + payload.len()];

            ipv6_header(src, dst, IpNextHeaderProtocols::Tcp, &mut buf);

            tcp_header(saddr, daddr, sport, dport, &payload, &mut buf[40..]);
            MutableIpPacket::owned(buf).unwrap()
        }
        (IpAddr::V6(_), IpAddr::V4(_)) | (IpAddr::V4(_), IpAddr::V6(_)) => {
            panic!("IPs must be of the same version")
        }
    }
}

pub fn udp_packet(
    saddr: IpAddr,
    daddr: IpAddr,
    sport: u16,
    dport: u16,
    payload: Vec<u8>,
) -> MutableIpPacket<'static> {
    match (saddr, daddr) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            use crate::ip::IpNextHeaderProtocols;

            let len = 20 + 8 + payload.len();
            let mut buf = vec![0u8; len];

            ipv4_header(src, dst, IpNextHeaderProtocols::Udp, &mut buf);

            udp_header(saddr, daddr, sport, dport, &payload, &mut buf[20..]);
            MutableIpPacket::owned(buf).unwrap()
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            use crate::ip::IpNextHeaderProtocols;

            let mut buf = vec![0u8; 40 + 8 + payload.len()];

            ipv6_header(src, dst, IpNextHeaderProtocols::Udp, &mut buf);

            udp_header(saddr, daddr, sport, dport, &payload, &mut buf[40..]);
            MutableIpPacket::owned(buf).unwrap()
        }
        (IpAddr::V6(_), IpAddr::V4(_)) | (IpAddr::V4(_), IpAddr::V6(_)) => {
            panic!("IPs must be of the same version")
        }
    }
}

pub fn dns_query(
    domain: Name,
    kind: RecordType,
    src: SocketAddr,
    dst: SocketAddr,
) -> MutableIpPacket<'static> {
    // TODO: This is wrong and not a full DNS query!

    let payload = hickory_proto::op::Query::query(domain, kind)
        .to_bytes()
        .unwrap();

    udp_packet(src.ip(), dst.ip(), src.port(), dst.port(), payload)
}

fn ipv4_header(src: Ipv4Addr, dst: Ipv4Addr, proto: IpNextHeaderProtocol, buf: &mut [u8]) {
    let len = buf.len();
    let mut ipv4_packet = MutableIpv4Packet::new(buf).unwrap();
    ipv4_packet.set_version(4);
    ipv4_packet.set_header_length(5);
    ipv4_packet.set_total_length(len as u16);
    ipv4_packet.set_ttl(64);
    ipv4_packet.set_next_level_protocol(proto);
    ipv4_packet.set_source(src);
    ipv4_packet.set_destination(dst);
    ipv4_packet.set_checksum(crate::ipv4::checksum(&ipv4_packet.to_immutable()));
}

fn ipv6_header(src: Ipv6Addr, dst: Ipv6Addr, proto: IpNextHeaderProtocol, buf: &mut [u8]) {
    let payload_len = buf.len() as u16 - 40;
    let mut ipv6_packet = MutableIpv6Packet::new(buf).unwrap();

    ipv6_packet.set_version(6);
    ipv6_packet.set_payload_length(payload_len);
    ipv6_packet.set_next_header(proto);
    ipv6_packet.set_hop_limit(64);
    ipv6_packet.set_source(src);
    ipv6_packet.set_destination(dst);
}

fn tcp_header(
    saddr: IpAddr,
    daddr: IpAddr,
    sport: u16,
    dport: u16,
    payload: &[u8],
    buf: &mut [u8],
) {
    let mut tcp_packet = MutableTcpPacket::new(buf).unwrap();
    tcp_packet.set_source(sport);
    tcp_packet.set_destination(dport);
    tcp_packet.set_sequence(0);
    tcp_packet.set_acknowledgement(0);
    tcp_packet.set_data_offset(5);
    tcp_packet.set_flags(0);
    tcp_packet.set_window(128);
    tcp_packet.set_payload(payload);
    match (saddr, daddr) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            tcp_packet.set_checksum(tcp::ipv4_checksum(&tcp_packet.to_immutable(), &src, &dst));
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            tcp_packet.set_checksum(tcp::ipv6_checksum(&tcp_packet.to_immutable(), &src, &dst));
        }
        _ => {
            panic!("IPs must be of the same version")
        }
    }
}

fn udp_header(
    saddr: IpAddr,
    daddr: IpAddr,
    sport: u16,
    dport: u16,
    payload: &[u8],
    buf: &mut [u8],
) {
    let mut udp_packet = MutableUdpPacket::new(buf).unwrap();
    udp_packet.set_source(sport);
    udp_packet.set_destination(dport);
    udp_packet.set_length(8 + payload.len() as u16);
    udp_packet.set_payload(payload);

    match (saddr, daddr) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            udp_packet.set_checksum(udp::ipv4_checksum(&udp_packet.to_immutable(), &src, &dst));
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            udp_packet.set_checksum(udp::ipv6_checksum(&udp_packet.to_immutable(), &src, &dst));
        }
        _ => {
            panic!("IPs must be of the same version")
        }
    }
}
