use std::net::Ipv4Addr;

use ingot::ip::{IpProtocol, Ipv4};
use ingot::tcp::{Tcp, TcpFlags};
use ingot::types::{Emit, HeaderLen as _};
use ingot::udp::Udp;
use ip_packet::{IpPacket, IpPacketBuf, checksum};
use packet_coalescer::{ChecksumMode, CoalescedPacket, PacketCoalescer, Protocol};

use super::split::split;
use super::virtio;
use super::virtio::*;

const SRC: [u8; 4] = [10, 0, 0, 1];
const DST: [u8; 4] = [10, 0, 0, 2];

#[test]
fn coalesced_tcp_packet_roundtrips_through_virtio_gso() {
    let mut coalescer =
        PacketCoalescer::new([Protocol::Tcp, Protocol::Udp], ChecksumMode::Offloaded);
    let segments = [
        tcp4_id(10, 1000, &[1; 100]),
        tcp4_id(11, 1100, &[2; 100]),
        tcp4_id(12, 1200, &[3; 50]),
    ];

    for segment in segments.clone() {
        coalescer.enqueue(segment);
    }

    let out = coalescer.drain().collect::<Vec<_>>();
    let [super_packet] = out.as_slice() else {
        panic!("expected one coalesced packet")
    };
    let buf = tun_write(super_packet);
    let (header, packet) = VirtioNetHdr::parse(&buf).unwrap();

    assert_eq!(
        header,
        VirtioNetHdr {
            flags: VIRTIO_NET_HDR_F_NEEDS_CSUM,
            gso_type: VIRTIO_NET_HDR_GSO_TCPV4,
            hdr_len: 40,
            gso_size: 100,
            csum_start: 20,
            csum_offset: 16,
        }
    );
    assert_eq!(packet.len(), 20 + 20 + 250);

    let roundtripped = split(&buf).unwrap();
    assert_eq!(roundtripped.len(), segments.len());

    for (original, roundtripped) in segments.iter().zip(&roundtripped) {
        assert_eq!(original.packet(), roundtripped.packet());
    }
}

#[test]
fn coalesced_udp_packet_roundtrips_through_virtio_gso() {
    let mut coalescer =
        PacketCoalescer::new([Protocol::Tcp, Protocol::Udp], ChecksumMode::Offloaded);
    let datagrams = [
        udp4_id(20, &[1; 100]),
        udp4_id(21, &[2; 100]),
        udp4_id(22, &[3; 30]),
    ];

    for datagram in datagrams.clone() {
        coalescer.enqueue(datagram);
    }

    let out = coalescer.drain().collect::<Vec<_>>();
    let [super_packet] = out.as_slice() else {
        panic!("expected one coalesced packet")
    };
    let buf = tun_write(super_packet);
    let (header, _) = VirtioNetHdr::parse(&buf).unwrap();

    assert_eq!(
        header,
        VirtioNetHdr {
            flags: VIRTIO_NET_HDR_F_NEEDS_CSUM,
            gso_type: VIRTIO_NET_HDR_GSO_UDP_L4,
            hdr_len: 28,
            gso_size: 100,
            csum_start: 20,
            csum_offset: 6,
        }
    );

    let roundtripped = split(&buf).unwrap();
    assert_eq!(roundtripped.len(), datagrams.len());

    for (original, roundtripped) in datagrams.iter().zip(&roundtripped) {
        assert_eq!(original.packet(), roundtripped.packet());
    }
}

#[test]
fn completes_offloaded_checksum_of_non_gso_packet() {
    let packet = udp4_id(0, &[7; 32]);
    let bytes = packet.packet();

    // Emulate a locally-generated packet with TUN_F_CSUM. The UDP checksum
    // field contains only the folded pseudo-header sum.
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
        IpProtocol::UDP,
        l4_len,
    ));
    buf[virtio::VNET_HDR_LEN + 26..virtio::VNET_HDR_LEN + 28]
        .copy_from_slice(&pseudo.to_be_bytes());

    let out = split(&buf).unwrap();
    let [completed] = out.as_slice() else {
        panic!("expected one packet")
    };

    assert_eq!(completed.packet(), packet.packet());
}

fn tcp4_id(id: u16, seq: u32, payload: &[u8]) -> IpPacket {
    let tcp = Tcp {
        source: 5000,
        destination: 6000,
        sequence: seq,
        acknowledgement: 42,
        flags: TcpFlags::ACK,
        window_size: 64000,
        ..Default::default()
    };

    ipv4_packet(id, IpProtocol::TCP, tcp, payload)
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

    let mut buf = IpPacketBuf::new();
    buf.buf()[..bytes.len()].copy_from_slice(&bytes);
    let mut packet = IpPacket::new(buf, bytes.len()).unwrap();
    packet.compute_checksums();

    packet
}

fn tun_write(packet: &CoalescedPacket) -> Vec<u8> {
    let mut buf = Vec::with_capacity(VNET_HDR_LEN + packet.packet().len());
    buf.extend_from_slice(&virtio::header_for(packet));
    buf.extend_from_slice(packet.packet());

    buf
}
