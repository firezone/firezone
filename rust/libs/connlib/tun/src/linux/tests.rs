use std::net::Ipv4Addr;

use ingot::ip::{IpProtocol, Ipv4};
use ingot::tcp::{Tcp, TcpFlags};
use ingot::types::{Emit, HeaderLen as _};
use ingot::udp::Udp;
use ip_packet::{IpPacket, IpPacketBuf};

use super::coalesce::{Outgoing, TunGsoQueue};
use super::split::split;
use super::virtio::*;
use super::{checksum, virtio};

const SRC: [u8; 4] = [10, 0, 0, 1];
const DST: [u8; 4] = [10, 0, 0, 2];

#[test]
fn coalesces_sequential_tcp_segments() {
    let mut queue = TunGsoQueue::new();

    queue.enqueue(tcp4(1000, &[1; 100]));
    queue.enqueue(tcp4(1100, &[2; 100]));
    queue.enqueue(tcp4(1200, &[3; 100]));

    let out = queue.drain().collect::<Vec<_>>();

    let [super_packet] = out.as_slice() else {
        panic!("Expected a single super packet");
    };
    assert_eq!(super_packet.num_segments(), 3);

    let buf = write_bytes(super_packet);
    let (hdr, packet) = VirtioNetHdr::parse(&buf).unwrap();

    assert_eq!(hdr.flags, VIRTIO_NET_HDR_F_NEEDS_CSUM);
    assert_eq!(hdr.gso_type, VIRTIO_NET_HDR_GSO_TCPV4);
    assert_eq!(hdr.gso_size, 100);
    assert_eq!(hdr.csum_start, 20);
    assert_eq!(hdr.csum_offset, 16);
    assert_eq!(hdr.hdr_len, 40);

    assert_eq!(packet.len(), 20 + 20 + 300);
    assert_eq!(
        u16::from_be_bytes([packet[2], packet[3]]) as usize,
        packet.len(),
        "IPv4 total length must cover all segments"
    );

    // The payloads must be concatenated in order.
    assert_eq!(&packet[40..140], &[1; 100]);
    assert_eq!(&packet[140..240], &[2; 100]);
    assert_eq!(&packet[240..340], &[3; 100]);
}

#[test]
fn coalesced_tcp_packet_splits_back_into_segments() {
    let mut queue = TunGsoQueue::new();

    let segments = [
        tcp4_id(10, 1000, &[1; 100]),
        tcp4_id(11, 1100, &[2; 100]),
        tcp4_id(12, 1200, &[3; 50]),
    ];

    for segment in segments.clone() {
        queue.enqueue(segment);
    }
    let out = queue.drain().collect::<Vec<_>>();

    let [super_packet] = out.as_slice() else {
        panic!("Expected a single super packet");
    };

    let roundtripped = split(&write_bytes(super_packet)).unwrap();

    assert_eq!(roundtripped.len(), 3);

    for (original, roundtripped) in segments.iter().zip(&roundtripped) {
        assert_eq!(original.packet(), roundtripped.packet());
    }
}

#[test]
fn super_packet_gathers_payloads_from_original_packets() {
    let mut queue = TunGsoQueue::new();

    queue.enqueue(tcp4(1000, &[1; 100]));
    queue.enqueue(tcp4(1100, &[2; 100]));

    let out = queue.drain().collect::<Vec<_>>();

    let [super_packet] = out.as_slice() else {
        panic!("Expected a single super packet");
    };

    let bufs = super_packet.bufs().collect::<Vec<_>>();

    let [prefix, first, second] = bufs.as_slice() else {
        panic!("Expected the header prefix plus one payload buffer per segment");
    };
    assert_eq!(prefix.len(), VNET_HDR_LEN + 20 + 20);
    assert_eq!(*first, [1u8; 100].as_slice());
    assert_eq!(*second, [2u8; 100].as_slice());
}

#[test]
fn does_not_coalesce_across_flows() {
    let mut queue = TunGsoQueue::new();

    queue.enqueue(tcp4(1000, &[1; 100]));
    queue.enqueue(tcp4_ports(7000, 8000, 9999, &[9; 100]));
    queue.enqueue(tcp4(1100, &[2; 100]));

    let out = queue.drain().collect::<Vec<_>>();

    assert_eq!(out.len(), 2);
    assert_eq!(out[0].num_segments(), 2);
    assert_eq!(out[1].num_segments(), 1);
}

#[test]
fn out_of_order_segment_starts_new_batch() {
    let mut queue = TunGsoQueue::new();

    queue.enqueue(tcp4(1000, &[1; 100]));
    queue.enqueue(tcp4(1500, &[2; 100])); // Gap in sequence numbers.

    let out = queue.drain().collect::<Vec<_>>();

    assert_eq!(out.len(), 2);
    assert_eq!(out[0].num_segments(), 1);
    assert_eq!(out[1].num_segments(), 1);
}

#[test]
fn psh_closes_the_batch() {
    let mut queue = TunGsoQueue::new();

    queue.enqueue(tcp4(1000, &[1; 100]));
    queue.enqueue(tcp4_psh(1100, &[2; 100]));
    queue.enqueue(tcp4(1200, &[3; 100])); // Must not join the batch closed by the PSH.

    let out = queue.drain().collect::<Vec<_>>();

    let [super_packet, segment] = out.as_slice() else {
        panic!("Expected a super packet followed by the post-PSH segment");
    };
    assert_eq!(super_packet.num_segments(), 2);
    assert_eq!(segment.num_segments(), 1);

    let buf = write_bytes(super_packet);
    let (_, packet) = VirtioNetHdr::parse(&buf).unwrap();
    assert_eq!(
        packet[33] & 0x08,
        0x08,
        "PSH must be set on the super packet"
    );
}

#[test]
fn short_segment_closes_the_batch() {
    let mut queue = TunGsoQueue::new();

    queue.enqueue(tcp4(1000, &[1; 100]));
    queue.enqueue(tcp4(1100, &[2; 40]));
    queue.enqueue(tcp4(1140, &[3; 100])); // Must not join the batch closed by the short segment.

    let out = queue.drain().collect::<Vec<_>>();

    assert_eq!(out.len(), 2, "A shorter segment must close the batch");
    assert_eq!(out[0].num_segments(), 2);
    assert_eq!(out[1].num_segments(), 1);
}

#[test]
fn non_candidate_flushes_same_flow_first() {
    let mut queue = TunGsoQueue::new();

    queue.enqueue(tcp4(1000, &[1; 100]));
    queue.enqueue(tcp4(1100, &[2; 100]));
    queue.enqueue(tcp4(1200, &[])); // Pure ACK, not a candidate.

    let out = queue.drain().collect::<Vec<_>>();

    // Ordering within the flow must be preserved: batch first, then the ACK.
    assert_eq!(out.len(), 2);
    assert_eq!(out[0].num_segments(), 2);
    assert_eq!(out[1].num_segments(), 1);
}

#[test]
fn coalesces_udp_datagrams() {
    let mut queue = TunGsoQueue::new();

    let datagrams = [
        udp4_id(20, &[1; 100]),
        udp4_id(21, &[2; 100]),
        udp4_id(22, &[3; 30]),
    ];

    for datagram in datagrams.clone() {
        queue.enqueue(datagram);
    }
    let out = queue.drain().collect::<Vec<_>>();

    let [super_packet] = out.as_slice() else {
        panic!("Expected a single super packet");
    };
    assert_eq!(super_packet.num_segments(), 3);

    let buf = write_bytes(super_packet);
    let (hdr, _) = VirtioNetHdr::parse(&buf).unwrap();
    assert_eq!(hdr.gso_type, VIRTIO_NET_HDR_GSO_UDP_L4);
    assert_eq!(hdr.gso_size, 100);
    assert_eq!(hdr.csum_offset, 6);

    let roundtripped = split(&buf).unwrap();

    assert_eq!(roundtripped.len(), 3);

    for (original, roundtripped) in datagrams.iter().zip(&roundtripped) {
        assert_eq!(original.packet(), roundtripped.packet());
    }
}

#[test]
fn completes_partial_checksum_of_non_gso_packet() {
    let packet = udp4(&[7; 32]);
    let bytes = packet.packet();

    // Emulate what the kernel hands us for a locally-generated packet with TUN_F_CSUM:
    // the UDP checksum field holds only the folded pseudo-header sum.
    let mut buf = Vec::new();
    buf.extend_from_slice(
        &VirtioNetHdr {
            flags: VIRTIO_NET_HDR_F_NEEDS_CSUM,
            gso_type: VIRTIO_NET_HDR_GSO_NONE,
            hdr_len: 0,
            gso_size: 0,
            csum_start: 20,
            csum_offset: 6,
        }
        .to_bytes(),
    );
    buf.extend_from_slice(bytes);

    let l4_len = bytes.len() - 20;
    let pseudo = checksum::fold(checksum::pseudo_header_sum_v4(
        Ipv4Addr::from(SRC),
        Ipv4Addr::from(DST),
        17,
        l4_len,
    ));
    buf[virtio::VNET_HDR_LEN + 26..virtio::VNET_HDR_LEN + 28]
        .copy_from_slice(&pseudo.to_be_bytes());

    let out = split(&buf).unwrap();

    let [completed] = out.as_slice() else {
        panic!("Expected a single packet")
    };

    assert_eq!(
        completed.packet(),
        packet.packet(),
        "Completing the partial checksum must reproduce the full checksum"
    );
}

fn tcp4(seq: u32, payload: &[u8]) -> IpPacket {
    tcp4_id(0, seq, payload)
}

fn tcp4_id(id: u16, seq: u32, payload: &[u8]) -> IpPacket {
    ipv4_packet(
        id,
        IpProtocol::TCP,
        tcp_header(5000, 6000, seq, false),
        payload,
    )
}

fn tcp4_ports(sport: u16, dport: u16, seq: u32, payload: &[u8]) -> IpPacket {
    ipv4_packet(
        0,
        IpProtocol::TCP,
        tcp_header(sport, dport, seq, false),
        payload,
    )
}

fn tcp4_psh(seq: u32, payload: &[u8]) -> IpPacket {
    ipv4_packet(
        0,
        IpProtocol::TCP,
        tcp_header(5000, 6000, seq, true),
        payload,
    )
}

fn udp4(payload: &[u8]) -> IpPacket {
    udp4_id(0, payload)
}

fn udp4_id(id: u16, payload: &[u8]) -> IpPacket {
    let udp = Udp {
        source: 5000,
        destination: 6000,
        length: (8 + payload.len()) as u16,
        checksum: 0,
    };

    ipv4_packet(id, IpProtocol::UDP, udp, payload)
}

fn tcp_header(sport: u16, dport: u16, seq: u32, psh: bool) -> Tcp {
    let mut flags = TcpFlags::ACK;
    flags.set(TcpFlags::PSH, psh);

    Tcp {
        source: sport,
        destination: dport,
        sequence: seq,
        acknowledgement: 42,
        flags,
        window_size: 64000,
        ..Default::default()
    }
}

fn ipv4_packet(id: u16, protocol: IpProtocol, l4_header: impl Emit, payload: &[u8]) -> IpPacket {
    let total_len = Ipv4::MINIMUM_LENGTH + l4_header.packet_length() + payload.len();

    let ipv4 = Ipv4 {
        ihl: 5,
        total_len: total_len as u16,
        identification: id,
        hop_limit: 64,
        protocol,
        source: Ipv4Addr::from(SRC).into(),
        destination: Ipv4Addr::from(DST).into(),
        ..Default::default()
    };

    let mut bytes = (ipv4, l4_header).to_vec();
    bytes.extend_from_slice(payload);

    let mut packet = packet_from_bytes(&bytes);
    packet.compute_checksums();

    packet
}

fn packet_from_bytes(bytes: &[u8]) -> IpPacket {
    let mut buf = IpPacketBuf::new();
    buf.buf()[..bytes.len()].copy_from_slice(bytes);

    IpPacket::new(buf, bytes.len()).unwrap()
}

/// Concatenates all buffers of an [`Outgoing`] into the byte stream `writev` produces.
fn write_bytes(outgoing: &Outgoing) -> Vec<u8> {
    outgoing.bufs().collect::<Vec<_>>().concat()
}
