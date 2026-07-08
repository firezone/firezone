use std::net::Ipv4Addr;

use ip_packet::{IpHeaders, IpPacket, IpPacketBuf, Ipv4Header, PacketBuilder, ip_number};

use super::coalesce::TunGsoQueue;
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

    let buf = super_packet.bufs().concat();
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

    let roundtripped = split(&super_packet.bufs().concat()).unwrap();

    assert_eq!(roundtripped.len(), 3);

    for (original, roundtripped) in segments.iter().zip(&roundtripped) {
        assert_eq!(original.packet(), roundtripped.packet());
    }
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

    let buf = super_packet.bufs().concat();
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

    let buf = super_packet.bufs().concat();
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
    let builder = PacketBuilder::ip(ipv4_header(id, ip_number::TCP))
        .tcp(5000, 6000, seq, 64000)
        .ack(42);

    let mut bytes = Vec::new();
    builder.write(&mut bytes, payload).unwrap();

    packet_from_bytes(&bytes)
}

fn tcp4_ports(sport: u16, dport: u16, seq: u32, payload: &[u8]) -> IpPacket {
    let builder = PacketBuilder::ipv4(SRC, DST, 64)
        .tcp(sport, dport, seq, 64000)
        .ack(42);

    let mut bytes = Vec::new();
    builder.write(&mut bytes, payload).unwrap();

    packet_from_bytes(&bytes)
}

fn tcp4_psh(seq: u32, payload: &[u8]) -> IpPacket {
    let builder = PacketBuilder::ipv4(SRC, DST, 64)
        .tcp(5000, 6000, seq, 64000)
        .ack(42)
        .psh();

    let mut bytes = Vec::new();
    builder.write(&mut bytes, payload).unwrap();

    packet_from_bytes(&bytes)
}

fn udp4(payload: &[u8]) -> IpPacket {
    udp4_id(0, payload)
}

fn udp4_id(id: u16, payload: &[u8]) -> IpPacket {
    let builder = PacketBuilder::ip(ipv4_header(id, ip_number::UDP)).udp(5000, 6000);

    let mut bytes = Vec::new();
    builder.write(&mut bytes, payload).unwrap();

    packet_from_bytes(&bytes)
}

fn ipv4_header(id: u16, protocol: ip_packet::IpNumber) -> IpHeaders {
    let mut header = Ipv4Header::new(0, 64, protocol, SRC, DST).unwrap();
    header.identification = id;

    IpHeaders::Ipv4(header, Default::default())
}

fn packet_from_bytes(bytes: &[u8]) -> IpPacket {
    let mut buf = IpPacketBuf::new();
    buf.buf()[..bytes.len()].copy_from_slice(bytes);

    IpPacket::new(buf, bytes.len()).unwrap()
}
