#![no_main]

use std::net::IpAddr;

use arbitrary::Arbitrary;
use ip_packet::{Ecn, IpPacket, IpPacketBuf};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: Input| {
    if input.data.len() > ip_packet::MAX_IP_SIZE {
        return;
    }

    let mut buf = IpPacketBuf::new();
    let len = input.data.len();
    buf.buf()[..len].copy_from_slice(&input.data[..len]);

    if let Ok(mut packet) = IpPacket::new(buf, len) {
        test_all_getters(&packet);

        for action in input.setters {
            match action {
                Setter::Src(ip_addr) => {
                    let _ = packet.set_src(ip_addr);
                }
                Setter::Dst(ip_addr) => {
                    let _ = packet.set_dst(ip_addr);
                }
                Setter::SrcProtocol(v) => {
                    packet.set_source_protocol(v);
                }
                Setter::DstProtocol(v) => {
                    packet.set_destination_protocol(v);
                }
                Setter::Ecn(ecn) => {
                    packet = packet.with_ecn_from_transport(ecn);
                }
            }

            test_all_getters(&packet);
        }
    }
});

#[derive(Arbitrary, Debug)]
struct Input<'a> {
    data: &'a [u8],
    setters: Vec<Setter>,
}

#[derive(Arbitrary, Debug)]
enum Setter {
    Src(IpAddr),
    Dst(IpAddr),
    SrcProtocol(u16),
    DstProtocol(u16),
    Ecn(Ecn),
}

fn test_all_getters(packet: &IpPacket) {
    let _ = packet.version();
    let _ = packet.source();
    let _ = packet.destination();
    let _ = packet.source_protocol();
    let _ = packet.destination_protocol();
    let _ = packet.ecn();
    let _ = packet.ipv4_header();
    let _ = packet.ipv6_header();
    let _ = packet.next_header();
    let _ = packet.is_udp();
    let _ = packet.is_tcp();
    let _ = packet.is_icmp();
    let _ = packet.is_icmpv6();
    let _ = packet.is_fz_p2p_control();
    let _ = packet.packet();
    let _ = packet.payload();
    let _ = packet.as_udp();
    let _ = packet.as_tcp();
    let _ = packet.as_icmpv4();
    let _ = packet.as_icmpv6();
    let _ = packet.as_fz_p2p_control();
    let _ = packet.calculate_udp_checksum();
    let _ = packet.calculate_tcp_checksum();
    let _ = packet.icmp_unreachable_destination();
}
