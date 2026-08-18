#![no_main]

use std::net::IpAddr;

use arbitrary::Arbitrary;
use ip_packet::{Ecn, IcmpError, IpPacket, IpPacketBuf, Protocol};
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

        // Parsing an ICMP error does not require valid checksums, so arbitrary
        // input can reach this directly.
        exercise_icmp_error(&packet, input.translate_dst, input.translate_port);

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
                Setter::UdpSrcPort(port) => {
                    if let Some(mut udp) = packet.as_udp_mut() {
                        udp.set_source_port(port);

                        assert_eq!(udp.get_source_port(), port);
                        let _ = udp.get_checksum();
                    }

                    // The raw slice setters don't maintain checksums.
                    packet.compute_checksums();
                }
                Setter::UdpDstPort(port) => {
                    if let Some(mut udp) = packet.as_udp_mut() {
                        udp.set_destination_port(port);

                        assert_eq!(udp.get_destination_port(), port);
                    }

                    packet.compute_checksums();
                }
                Setter::TcpSrcPort(port) => {
                    if let Some(mut tcp) = packet.as_tcp_mut() {
                        tcp.set_source_port(port);

                        assert_eq!(tcp.get_source_port(), port);
                        let _ = tcp.get_checksum();
                    }

                    packet.compute_checksums();
                }
                Setter::TcpDstPort(port) => {
                    if let Some(mut tcp) = packet.as_tcp_mut() {
                        tcp.set_destination_port(port);

                        assert_eq!(tcp.get_destination_port(), port);
                    }

                    packet.compute_checksums();
                }
                Setter::Icmpv4Identifier(id) => {
                    if let Some(mut icmp) = packet.as_icmpv4_mut() {
                        // The identifier only exists for echo requests and replies.
                        if icmp.is_echo_request_or_reply() {
                            icmp.set_identifier(id);

                            assert_eq!(icmp.get_identifier(), id);
                        }

                        let _ = icmp.get_checksum();
                    }

                    packet.compute_checksums();
                }
                Setter::Icmpv6Identifier(id) => {
                    if let Some(mut icmp) = packet.as_icmpv6_mut() {
                        // The identifier only exists for echo requests and replies.
                        if icmp.is_echo_request_or_reply() {
                            icmp.set_identifier(id);

                            assert_eq!(icmp.get_identifier(), id);
                        }

                        let _ = icmp.get_checksum();
                    }

                    packet.compute_checksums();
                }
            }

            test_all_getters(&packet);

            let errors = checksum_errors(&packet);
            assert!(
                errors.is_empty(),
                "mutators broke checksums: {errors:?}\npacket: {packet:?}"
            );
        }

        make_and_parse_icmp_errors(&packet, input.translate_dst, input.translate_port);
    }
});

/// Builds ICMP destination-unreachable errors from the packet and parses them back.
fn make_and_parse_icmp_errors(packet: &IpPacket, translate_dst: IpAddr, translate_port: u16) {
    type MakeError = fn(&IpPacket) -> anyhow::Result<IpPacket>;
    type IsCode = fn(&IcmpError) -> bool;

    let cases: [(MakeError, IsCode); 2] = [
        (
            ip_packet::make::icmp_dest_unreachable_prohibited,
            IcmpError::is_unreachable_prohibited,
        ),
        (
            ip_packet::make::icmp_dest_unreachable_network,
            IcmpError::is_unreachable_network,
        ),
    ];

    for (make_error, is_code) in cases {
        let Ok(error_packet) = make_error(packet) else {
            continue;
        };

        test_all_getters(&error_packet);

        assert_eq!(error_packet.source(), packet.destination());
        assert_eq!(error_packet.destination(), packet.source());

        let errors = checksum_errors(&error_packet);
        assert!(
            errors.is_empty(),
            "constructed ICMP error has broken checksums: {errors:?}\npacket: {error_packet:?}"
        );

        // An IPv4 UDP or TCP packet always embeds its full IP header plus at least
        // the ports, so parsing the error back must succeed.
        if matches!(packet.source(), IpAddr::V4(_)) && (packet.is_udp() || packet.is_tcp()) {
            let (failed, icmp_error) = error_packet
                .icmp_error()
                .unwrap_or_else(|e| {
                    panic!("failed to parse constructed ICMP error: {e:#}\npacket: {packet:?}")
                })
                .expect("constructed ICMP error should contain a failed packet");

            assert_eq!(failed.src(), packet.source());
            assert_eq!(failed.dst(), packet.destination());
            assert_eq!(
                failed.src_proto(),
                packet
                    .source_protocol()
                    .expect("UDP/TCP packets always have a source protocol")
            );
            assert_eq!(
                failed.dst_proto(),
                packet
                    .destination_protocol()
                    .expect("UDP/TCP packets always have a destination protocol")
            );
            assert!(is_code(&icmp_error));
        }

        exercise_icmp_error(&error_packet, translate_dst, translate_port);
    }
}

/// Exercises the ICMP error API on any packet that parses as an ICMP error.
fn exercise_icmp_error(packet: &IpPacket, translate_dst: IpAddr, translate_port: u16) {
    let Ok(Some((failed, icmp_error))) = packet.icmp_error() else {
        return;
    };

    let _ = failed.layer4_protocol();
    let _ = failed.dst_proto();
    let _ = icmp_error.is_unreachable_prohibited();
    let _ = icmp_error.is_unreachable_network();
    let _ = icmp_error.clone().into_icmp_v4_type();
    let _ = icmp_error.clone().into_icmp_v6_type();
    let _ = format!("{icmp_error} / {failed:?}");

    // Translating to the failed destination itself exercises the same-version paths.
    let dst = failed.dst();
    let src_proto = failed.src_proto();
    let _ = failed.translate_destination(dst, src_proto);

    // An arbitrary destination also reaches the version-mismatch arms. Keep the
    // protocol type intact: `translate_destination` assumes it matches the failed
    // packet's L4 protocol and may index out of bounds otherwise.
    if let Ok(Some((failed, _))) = packet.icmp_error() {
        let src_proto = failed.src_proto().with_value(translate_port);
        let _ = failed.translate_destination(translate_dst, src_proto);
    }
}

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
    translate_dst: IpAddr,
    translate_port: u16,
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
    UdpSrcPort(u16),
    UdpDstPort(u16),
    TcpSrcPort(u16),
    TcpDstPort(u16),
    Icmpv4Identifier(u16),
    Icmpv6Identifier(u16),
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
