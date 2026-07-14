//! Micro-benchmarks for parsing and inspecting IP packets.
//!
//! The benchmarks build raw packet bytes without depending on the crate's
//! internal parser, so the same file can be run against different implementations
//! of `ip-packet` to compare them.

#![allow(clippy::unwrap_used)]

use ip_packet::{IpPacket, IpPacketBuf};

fn main() {
    divan::main()
}

/// The kinds of packets we benchmark.
///
/// The "normal" kinds carry a 64-byte transport payload; `UdpV4Jumbo` carries a
/// near-MTU payload to show that parsing cost is independent of the payload size.
#[derive(Clone, Copy)]
enum Kind {
    UdpV4,
    UdpV6,
    TcpV4,
    TcpV6,
    IcmpV4,
    IcmpV6,
    UdpV4Jumbo,
}

const KINDS: [Kind; 7] = [
    Kind::UdpV4,
    Kind::UdpV6,
    Kind::TcpV4,
    Kind::TcpV6,
    Kind::IcmpV4,
    Kind::IcmpV6,
    Kind::UdpV4Jumbo,
];

const PAYLOAD_LEN: usize = 64;
const JUMBO_PAYLOAD_LEN: usize = 1200;

/// Parses a fresh buffer into an [`IpPacket`], validating its layout.
#[divan::bench(args = KINDS)]
fn parse(bencher: divan::Bencher, kind: Kind) {
    bencher
        .with_inputs(|| kind.buf())
        .bench_values(|(buf, len)| divan::black_box(IpPacket::new(buf, len).unwrap()));
}

/// Extracts the routing five-tuple (src/dst IP and src/dst protocol) from an
/// already-parsed packet, i.e. the per-packet work `connlib` does when routing.
#[divan::bench(args = KINDS)]
fn route(bencher: divan::Bencher, kind: Kind) {
    let (buf, len) = kind.buf();
    let packet = IpPacket::new(buf, len).unwrap();

    bencher.bench_local(|| {
        (
            divan::black_box(packet.source()),
            divan::black_box(packet.destination()),
            divan::black_box(packet.source_protocol()),
            divan::black_box(packet.destination_protocol()),
        )
    });
}

/// Reads the transport-layer payload length of an already-parsed packet.
#[divan::bench(args = KINDS)]
fn payload_len(bencher: divan::Bencher, kind: Kind) {
    let (buf, len) = kind.buf();
    let packet = IpPacket::new(buf, len).unwrap();

    bencher.bench_local(|| divan::black_box(packet.layer4_payload_len()));
}

impl Kind {
    fn buf(self) -> (IpPacketBuf, usize) {
        let bytes = self.bytes();

        let mut buf = IpPacketBuf::new();
        buf.buf()[..bytes.len()].copy_from_slice(&bytes);

        (buf, bytes.len())
    }

    fn bytes(self) -> Vec<u8> {
        const ICMP: u8 = 1;
        const TCP: u8 = 6;
        const UDP: u8 = 17;
        const ICMP_V6: u8 = 58;

        match self {
            Kind::UdpV4 => ipv4(UDP, &udp(PAYLOAD_LEN)),
            Kind::UdpV6 => ipv6(UDP, &udp(PAYLOAD_LEN)),
            Kind::TcpV4 => ipv4(TCP, &tcp(PAYLOAD_LEN)),
            Kind::TcpV6 => ipv6(TCP, &tcp(PAYLOAD_LEN)),
            Kind::IcmpV4 => ipv4(ICMP, &icmp(8)),
            Kind::IcmpV6 => ipv6(ICMP_V6, &icmp(128)),
            Kind::UdpV4Jumbo => ipv4(UDP, &udp(JUMBO_PAYLOAD_LEN)),
        }
    }
}

impl std::fmt::Display for Kind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let name = match self {
            Kind::UdpV4 => "udp_v4",
            Kind::UdpV6 => "udp_v6",
            Kind::TcpV4 => "tcp_v4",
            Kind::TcpV6 => "tcp_v6",
            Kind::IcmpV4 => "icmp_v4",
            Kind::IcmpV6 => "icmp_v6",
            Kind::UdpV4Jumbo => "udp_v4_jumbo",
        };

        f.write_str(name)
    }
}

/// Wraps a layer-4 segment in an IPv4 header.
fn ipv4(protocol: u8, l4: &[u8]) -> Vec<u8> {
    let total_len = 20 + l4.len();

    let mut packet = vec![0u8; 20];
    packet[0] = 0x45; // Version 4, IHL 5.
    packet[2..4].copy_from_slice(&(total_len as u16).to_be_bytes());
    packet[8] = 64; // TTL.
    packet[9] = protocol;
    packet[12..16].copy_from_slice(&[10, 0, 0, 1]); // Source.
    packet[16..20].copy_from_slice(&[10, 0, 0, 2]); // Destination.
    packet.extend_from_slice(l4);

    packet
}

/// Wraps a layer-4 segment in an IPv6 header.
fn ipv6(next_header: u8, l4: &[u8]) -> Vec<u8> {
    let mut packet = vec![0u8; 40];
    packet[0] = 0x60; // Version 6.
    packet[4..6].copy_from_slice(&(l4.len() as u16).to_be_bytes());
    packet[6] = next_header;
    packet[7] = 64; // Hop limit.
    packet[8..24].copy_from_slice(&[0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]); // Source.
    packet[24..40].copy_from_slice(&[0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]); // Destination.
    packet.extend_from_slice(l4);

    packet
}

fn udp(payload_len: usize) -> Vec<u8> {
    let len = 8 + payload_len;

    let mut segment = vec![0u8; 8];
    segment[0..2].copy_from_slice(&1111u16.to_be_bytes()); // Source port.
    segment[2..4].copy_from_slice(&2222u16.to_be_bytes()); // Destination port.
    segment[4..6].copy_from_slice(&(len as u16).to_be_bytes()); // Length.
    segment.resize(len, 0);

    segment
}

fn tcp(payload_len: usize) -> Vec<u8> {
    let mut segment = vec![0u8; 20];
    segment[0..2].copy_from_slice(&1111u16.to_be_bytes()); // Source port.
    segment[2..4].copy_from_slice(&2222u16.to_be_bytes()); // Destination port.
    segment[12] = 5 << 4; // Data offset 5 (20 bytes), no options.
    segment[13] = 0b0001_0000; // ACK.
    segment[14..16].copy_from_slice(&64240u16.to_be_bytes()); // Window size.
    segment.resize(20 + payload_len, 0);

    segment
}

fn icmp(ty: u8) -> Vec<u8> {
    let mut message = vec![0u8; 8];
    message[0] = ty; // Echo request (8 for ICMPv4, 128 for ICMPv6).
    message[4..6].copy_from_slice(&1u16.to_be_bytes()); // Identifier.
    message[6..8].copy_from_slice(&1u16.to_be_bytes()); // Sequence number.
    message.resize(8 + PAYLOAD_LEN, 0);

    message
}
