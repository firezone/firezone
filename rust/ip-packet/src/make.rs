//! Factory module for making all kinds of packets.

use crate::MutableIpPacket;
use std::net::IpAddr;

pub fn icmp_request_packet(source: IpAddr, dst: IpAddr) -> MutableIpPacket<'static> {
    match (source, dst) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            use crate::{
                icmp::{
                    echo_request::{IcmpCodes, MutableEchoRequestPacket},
                    IcmpTypes, MutableIcmpPacket,
                },
                ip::IpNextHeaderProtocols,
                ipv4::MutableIpv4Packet,
                MutablePacket as _, Packet as _,
            };

            let mut buf = vec![0u8; 60];

            let mut ipv4_packet = MutableIpv4Packet::new(&mut buf[..]).unwrap();
            ipv4_packet.set_version(4);
            ipv4_packet.set_header_length(5);
            ipv4_packet.set_total_length(60);
            ipv4_packet.set_ttl(64);
            ipv4_packet.set_next_level_protocol(IpNextHeaderProtocols::Icmp);
            ipv4_packet.set_source(src);
            ipv4_packet.set_destination(dst);
            ipv4_packet.set_checksum(crate::ipv4::checksum(&ipv4_packet.to_immutable()));

            let mut icmp_packet = MutableIcmpPacket::new(&mut buf[20..]).unwrap();
            icmp_packet.set_icmp_type(IcmpTypes::EchoRequest);
            icmp_packet.set_icmp_code(IcmpCodes::NoCode);
            icmp_packet.set_checksum(0);

            let mut echo_request_packet =
                MutableEchoRequestPacket::new(icmp_packet.payload_mut()).unwrap();
            echo_request_packet.set_sequence_number(1);
            echo_request_packet.set_identifier(0);
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
                ipv6::MutableIpv6Packet,
                MutablePacket as _,
            };

            let mut buf = vec![0u8; 128];

            let mut ipv6_packet = MutableIpv6Packet::new(&mut buf[..]).unwrap();

            ipv6_packet.set_version(6);
            ipv6_packet.set_payload_length(16);
            ipv6_packet.set_next_header(IpNextHeaderProtocols::Icmpv6);
            ipv6_packet.set_hop_limit(64);
            ipv6_packet.set_source(src);
            ipv6_packet.set_destination(dst);

            let mut icmp_packet = MutableIcmpv6Packet::new(&mut buf[40..]).unwrap();

            icmp_packet.set_icmpv6_type(Icmpv6Types::EchoRequest);
            icmp_packet.set_icmpv6_code(Icmpv6Code::new(0)); // No code for echo request

            let mut echo_request_packet =
                MutableEchoRequestPacket::new(icmp_packet.payload_mut()).unwrap();
            echo_request_packet.set_identifier(0);
            echo_request_packet.set_sequence_number(1);
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
