#![no_main]

use std::net::IpAddr;

use arbitrary::Arbitrary;
use ip_packet::{Ecn, IpPacket, IpPacketBuf, Protocol};
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

        // The mutators patch checksums incrementally: a packet with correct checksums
        // must still have correct checksums after any sequence of mutations. Arbitrary
        // input rarely has correct checksums to begin with, so fix them up first.
        packet.compute_checksums();

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
                Setter::TranslateSrc(protocol, src) => {
                    let _ = packet.translate_source(protocol, src);
                }
                Setter::TranslateDst(protocol, dst) => {
                    let _ = packet.translate_destination(protocol, dst);
                }
            }

            test_all_getters(&packet);

            let errors = checksum_errors(&packet);
            assert!(
                errors.is_empty(),
                "mutators broke checksums: {errors:?}\npacket: {packet:?}"
            );
        }
    }
});

/// Compares all stored checksums of the packet against a full recomputation.
fn checksum_errors(packet: &IpPacket) -> Vec<String> {
    let mut errors = Vec::new();

    if let (Some(hdr), Ok(expected)) = (
        packet.ipv4_header(),
        packet.calculate_ipv4_header_checksum(),
    ) {
        let stored = hdr.checksum();

        if !checksum_matches(stored, expected) {
            errors.push(format!(
                "IPv4 header checksum: stored {stored:#06x}, expected {expected:#06x}"
            ));
        }
    }

    if let (Some(udp), Ok(expected)) = (packet.as_udp(), packet.calculate_udp_checksum()) {
        let stored = udp.checksum();

        // Over IPv4 a zero checksum means "not computed" and the mutators leave it as such.
        // Over IPv6 the checksum is mandatory, so zero is always a bug there.
        let ipv4_not_computed = matches!(packet.source(), IpAddr::V4(_)) && stored == 0;

        if !ipv4_not_computed && !checksum_matches(stored, expected) {
            errors.push(format!(
                "UDP checksum: stored {stored:#06x}, expected {expected:#06x}"
            ));
        }
    }

    if let (Some(tcp), Ok(expected)) = (packet.as_tcp(), packet.calculate_tcp_checksum()) {
        let stored = tcp.checksum();

        if !checksum_matches(stored, expected) {
            errors.push(format!(
                "TCP checksum: stored {stored:#06x}, expected {expected:#06x}"
            ));
        }
    }

    if let (Some(icmp), Ok(expected)) = (packet.as_icmpv4(), packet.calculate_icmpv4_checksum()) {
        let stored = icmp.checksum();

        if !checksum_matches(stored, expected) {
            errors.push(format!(
                "ICMPv4 checksum: stored {stored:#06x}, expected {expected:#06x}"
            ));
        }
    }

    if let (Some(icmp), Ok(expected)) = (packet.as_icmpv6(), packet.calculate_icmpv6_checksum()) {
        let stored = icmp.checksum();

        if !checksum_matches(stored, expected) {
            errors.push(format!(
                "ICMPv6 checksum: stored {stored:#06x}, expected {expected:#06x}"
            ));
        }
    }

    errors
}

/// The incremental updates emit 0xFFFF where a from-scratch computation arrives at
/// 0x0000: both encode zero in one's complement and both verify on the wire, but only
/// 0xFFFF also verifies for all-zero data (see `ChecksumUpdate::into_ip_checksum`).
fn checksum_matches(stored: u16, expected: u16) -> bool {
    stored == expected || (expected == 0x0000 && stored == 0xFFFF)
}

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
    TranslateSrc(Protocol, IpAddr),
    TranslateDst(Protocol, IpAddr),
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
    let _ = packet.icmp_error();

    let _ = format!("{packet:?}"); // Debug printing also uses getters internally.
}
