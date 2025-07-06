#![no_main]

use ip_packet::{IpPacket, IpPacketBuf};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if data.len() > ip_packet::MAX_IP_SIZE {
        return;
    }

    let mut buf = IpPacketBuf::new();
    let len = data.len();
    buf.buf()[..len].copy_from_slice(&data[..len]);

    if let Ok(packet) = IpPacket::new(buf, len) {
        test_all_getters(&packet);
    }
});

fn test_all_getters(packet: &IpPacket) {
    // Test all getter methods - any panic will crash the fuzzer and be saved as an artifact
    // This is the correct behavior: we want the fuzzer to detect panics as failures

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

    // Test protocol-specific getters
    let _ = packet.as_udp();
    let _ = packet.as_tcp();
    let _ = packet.as_icmpv4();
    let _ = packet.as_icmpv6();
    let _ = packet.as_fz_p2p_control();

    // Test checksum calculation methods
    let _ = packet.calculate_udp_checksum();
    let _ = packet.calculate_tcp_checksum();

    // Test ICMP unreachable destination parsing
    let _ = packet.icmp_unreachable_destination();

    // Test ECN manipulation methods with the packet
    use ip_packet::Ecn;
    for ecn in [Ecn::Ce, Ecn::Ect0, Ecn::Ect1, Ecn::NonEct] {
        let cloned = packet.clone();
        let _ = cloned.with_ecn_from_transport(ecn);
    }
}
