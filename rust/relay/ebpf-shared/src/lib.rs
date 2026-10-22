//! Shared data structures between the kernel and userspace.
//!
//! In order to make sure endianness is correct, we store everything in byte-arrays in _big-endian_ order.
//! This makes it easier to directly take the values from the network buffer and use them in these structs (and vice-versa).

#![cfg_attr(not(feature = "std"), no_std)]

use core::net::{IpAddr, Ipv4Addr, Ipv6Addr};

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "std", derive(Debug))]
pub struct ClientAndChannelV4 {
    ipv4_address: [u8; 4],
    port: [u8; 2],
    channel: [u8; 2],
}

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "std", derive(Debug))]
pub struct ClientAndChannelV6 {
    ipv6_address: [u8; 16],
    port: [u8; 2],
    channel: [u8; 2],
}

#[repr(C)]
#[derive(Clone, Copy, derive_more::From)]
#[cfg_attr(feature = "std", derive(Debug))]
pub enum ClientAndChannel {
    V4(ClientAndChannelV4),
    V6(ClientAndChannelV6),
}

impl ClientAndChannel {
    pub fn client_ip(&self) -> IpAddr {
        match self {
            ClientAndChannel::V4(cc) => cc.client_ip().into(),
            ClientAndChannel::V6(cc) => cc.client_ip().into(),
        }
    }

    pub fn client_port(&self) -> u16 {
        match self {
            ClientAndChannel::V4(cc) => cc.client_port(),
            ClientAndChannel::V6(cc) => cc.client_port(),
        }
    }

    pub fn channel(&self) -> u16 {
        match self {
            ClientAndChannel::V4(cc) => cc.channel(),
            ClientAndChannel::V6(cc) => cc.channel(),
        }
    }
}

impl ClientAndChannelV4 {
    pub fn new(ipv4_address: Ipv4Addr, port: u16, channel: u16) -> Self {
        Self {
            ipv4_address: ipv4_address.octets(),
            port: port.to_be_bytes(),
            channel: channel.to_be_bytes(),
        }
    }

    pub fn from_socket(src: core::net::SocketAddrV4, channel: u16) -> Self {
        Self::new(*src.ip(), src.port(), channel)
    }

    pub fn client_ip(&self) -> Ipv4Addr {
        self.ipv4_address.into()
    }

    pub fn client_port(&self) -> u16 {
        u16::from_be_bytes(self.port)
    }

    pub fn channel(&self) -> u16 {
        u16::from_be_bytes(self.channel)
    }
}

impl ClientAndChannelV6 {
    pub fn new(ipv6_address: Ipv6Addr, port: u16, channel: u16) -> Self {
        Self {
            ipv6_address: ipv6_address.octets(),
            port: port.to_be_bytes(),
            channel: channel.to_be_bytes(),
        }
    }

    pub fn from_socket(src: core::net::SocketAddrV6, channel: u16) -> Self {
        Self::new(*src.ip(), src.port(), channel)
    }

    pub fn client_ip(&self) -> Ipv6Addr {
        self.ipv6_address.into()
    }

    pub fn client_port(&self) -> u16 {
        u16::from_be_bytes(self.port)
    }

    pub fn channel(&self) -> u16 {
        u16::from_be_bytes(self.channel)
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "std", derive(Debug))]
pub struct PortAndPeerV4 {
    ipv4_address: [u8; 4],
    allocation_port: [u8; 2],
    peer_port: [u8; 2],
}

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "std", derive(Debug))]
pub struct PortAndPeerV6 {
    ipv6_address: [u8; 16],

    allocation_port: [u8; 2],
    peer_port: [u8; 2],
}

#[repr(C)]
#[derive(Clone, Copy, derive_more::From)]
#[cfg_attr(feature = "std", derive(Debug))]
pub enum PortAndPeer {
    V4(PortAndPeerV4),
    V6(PortAndPeerV6),
}

impl PortAndPeer {
    pub fn peer_ip(&self) -> IpAddr {
        match self {
            PortAndPeer::V4(pp) => pp.peer_ip().into(),
            PortAndPeer::V6(pp) => pp.peer_ip().into(),
        }
    }

    pub fn peer_port(&self) -> u16 {
        match self {
            PortAndPeer::V4(pp) => pp.peer_port(),
            PortAndPeer::V6(pp) => pp.peer_port(),
        }
    }

    pub fn allocation_port(&self) -> u16 {
        match self {
            PortAndPeer::V4(pp) => pp.allocation_port(),
            PortAndPeer::V6(pp) => pp.allocation_port(),
        }
    }

    /// Flips the allocation and peer port.
    ///
    /// When sending out a packet:
    /// - the allocation port is the source
    /// - the peer port is the destination
    ///
    /// When receiving a packet:
    /// - the allocation port is the destination
    /// - the peer port is the source
    ///
    /// When sending a packet to ourselves, we therefore need to flip these ports.
    /// 1. The allocation port becomes the source port of the packet.
    /// 2. The peer port becomes the destination of the packet.
    pub fn flip_ports(self) -> Self {
        match self {
            PortAndPeer::V4(pp) => PortAndPeer::V4(PortAndPeerV4 {
                ipv4_address: pp.ipv4_address,
                allocation_port: pp.peer_port,
                peer_port: pp.allocation_port,
            }),
            PortAndPeer::V6(pp) => PortAndPeer::V6(PortAndPeerV6 {
                ipv6_address: pp.ipv6_address,
                allocation_port: pp.peer_port,
                peer_port: pp.allocation_port,
            }),
        }
    }
}

impl PortAndPeerV4 {
    pub fn new(ipv4_address: Ipv4Addr, allocation_port: u16, peer_port: u16) -> Self {
        Self {
            ipv4_address: ipv4_address.octets(),
            allocation_port: allocation_port.to_be_bytes(),
            peer_port: peer_port.to_be_bytes(),
        }
    }

    pub fn from_socket(dst: core::net::SocketAddrV4, allocation_port: u16) -> Self {
        Self::new(*dst.ip(), allocation_port, dst.port())
    }

    pub fn peer_ip(&self) -> Ipv4Addr {
        self.ipv4_address.into()
    }

    pub fn allocation_port(&self) -> u16 {
        u16::from_be_bytes(self.allocation_port)
    }

    pub fn peer_port(&self) -> u16 {
        u16::from_be_bytes(self.peer_port)
    }
}

impl PortAndPeerV6 {
    pub fn new(ipv6_address: Ipv6Addr, allocation_port: u16, peer_port: u16) -> Self {
        Self {
            ipv6_address: ipv6_address.octets(),

            allocation_port: allocation_port.to_be_bytes(),
            peer_port: peer_port.to_be_bytes(),
        }
    }

    pub fn from_socket(dst: core::net::SocketAddrV6, allocation_port: u16) -> Self {
        Self::new(*dst.ip(), allocation_port, dst.port())
    }

    pub fn peer_ip(&self) -> Ipv6Addr {
        self.ipv6_address.into()
    }

    pub fn allocation_port(&self) -> u16 {
        u16::from_be_bytes(self.allocation_port)
    }

    pub fn peer_port(&self) -> u16 {
        u16::from_be_bytes(self.peer_port)
    }
}

/// Local perf-buffer ABI: integer fields use native endianness on the shared host.
/// IP version and ECN are individual bytes and have no byte-order conversion.
#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "std", derive(Debug))]
pub struct StatsEvent {
    // UDP packet lengths fit in u16; u32 leaves room for metadata within 16 bytes.
    relayed_data: u32,
    ip_version: u8,
    ecn: u8,
    // Explicitly initialized padding keeps the perf record at 16 bytes.
    reserved: [u8; 2],
    processing_duration_ns: u64,
}

impl StatsEvent {
    pub fn new(
        relayed_data: u16,
        processing_duration: core::time::Duration,
        ip_version: u8,
        ecn: u8,
    ) -> Self {
        Self {
            relayed_data: u32::from(relayed_data),
            processing_duration_ns: duration_as_nanos_u64(processing_duration),
            ip_version,
            ecn,
            reserved: [0; 2],
        }
    }

    pub fn relayed_data(&self) -> u64 {
        u64::from(self.relayed_data)
    }

    /// Incoming IP version, before address-family translation.
    pub fn ip_version(&self) -> u8 {
        self.ip_version
    }

    /// Incoming ECN codepoint: Not-ECT (0), ECT(1) (1), ECT(0) (2), or CE (3).
    pub fn ecn(&self) -> u8 {
        self.ecn
    }

    /// Time the XDP program spent processing this packet.
    pub fn processing_duration(&self) -> core::time::Duration {
        core::time::Duration::from_nanos(self.processing_duration_ns)
    }

    #[cfg(feature = "std")]
    pub fn from_bytes(bytes: &[u8]) -> Option<Self> {
        let (packet_chunk, rest) = bytes.split_first_chunk::<8>()?;
        let (duration_chunk, _) = rest.split_first_chunk::<8>()?;

        Some(Self {
            relayed_data: u32::from_ne_bytes(packet_chunk[..4].try_into().ok()?),
            ip_version: packet_chunk[4],
            ecn: packet_chunk[5],
            reserved: [packet_chunk[6], packet_chunk[7]],
            processing_duration_ns: u64::from_ne_bytes(*duration_chunk),
        })
    }

    /// Parses a [`StatsEvent`] from a perf-buffer sample split into up to two chunks.
    ///
    /// A sample that straddles the ring-buffer boundary arrives as two slices; `tail` is empty
    /// for samples that fit contiguously.
    #[cfg(feature = "std")]
    pub fn from_chunks(head: &[u8], tail: &[u8]) -> Option<Self> {
        if tail.is_empty() {
            return Self::from_bytes(head);
        }

        let mut bytes = [0_u8; core::mem::size_of::<Self>()];

        let head_len = head.len().min(bytes.len());
        let (head_dst, tail_dst) = bytes.split_at_mut(head_len);
        head_dst.copy_from_slice(&head[..head_len]);

        let tail_len = tail.len().min(tail_dst.len());
        tail_dst[..tail_len].copy_from_slice(&tail[..tail_len]);

        if head_len + tail_len < bytes.len() {
            return None;
        }

        Self::from_bytes(&bytes)
    }
}

#[inline]
fn duration_as_nanos_u64(d: core::time::Duration) -> u64 {
    // Stays in u64; avoids `Duration::as_nanos`'s u128 path for the BPF target.
    d.as_secs() * 1_000_000_000 + d.subsec_nanos() as u64
}

#[cfg(all(test, feature = "std"))]
mod stats_event_tests {
    use super::*;
    use network_types::ip::{Ipv4Hdr, Ipv6Hdr};

    #[test]
    fn extracts_ecn_from_network_order_headers() {
        for dscp in 0..=63_u8 {
            for ecn in 0..=3_u8 {
                let traffic_class = (dscp << 2) | ecn;
                let mut ipv4_bytes = [0_u8; Ipv4Hdr::LEN];
                ipv4_bytes[0] = 0x45;
                ipv4_bytes[1] = traffic_class;
                // SAFETY: Ipv4Hdr contains only bytes and byte arrays, with no padding.
                let ipv4: Ipv4Hdr = unsafe { core::mem::transmute(ipv4_bytes) };
                assert_eq!(ipv4.ecn(), ecn);

                let mut ipv6_bytes = [0_u8; Ipv6Hdr::LEN];
                ipv6_bytes[0] = 0x60 | (traffic_class >> 4);
                ipv6_bytes[1] = (traffic_class << 4) | 0x0f;
                // SAFETY: Ipv6Hdr contains only bytes and byte arrays, with no padding.
                let ipv6: Ipv6Hdr = unsafe { core::mem::transmute(ipv6_bytes) };
                assert_eq!(ipv6.ecn(), ecn);
                for (version, codepoint) in [(4, ipv4.ecn()), (6, ipv6.ecn())] {
                    let event = StatsEvent::new(0, core::time::Duration::ZERO, version, codepoint);
                    // SAFETY: StatsEvent has no implicit padding and every field is initialized.
                    let bytes: [u8; 16] = unsafe { core::mem::transmute(event) };
                    let parsed = StatsEvent::from_bytes(&bytes).unwrap();
                    assert_eq!(parsed.ip_version(), version);
                    assert_eq!(parsed.ecn(), ecn);
                }
            }
        }
    }

    #[test]
    fn from_bytes_roundtrips_the_wire_format() {
        let original = StatsEvent::new(4242, core::time::Duration::from_nanos(9999), 6, 3);

        // The kernel writes the struct's bytes verbatim into the perf buffer; lock in that the
        // wire format matches the `#[repr(C)]` in-memory layout.
        // SAFETY: StatsEvent has no implicit padding and every field is initialized.
        let bytes: [u8; 16] = unsafe { core::mem::transmute(original) };

        let parsed = StatsEvent::from_bytes(&bytes).expect("size-matching slice parses");

        assert_eq!(parsed.ip_version(), original.ip_version());
        assert_eq!(parsed.ecn(), original.ecn());
        assert_eq!(parsed.relayed_data(), original.relayed_data());
        assert_eq!(
            parsed.processing_duration_ns,
            original.processing_duration_ns
        );
    }

    #[test]
    fn from_chunks_reassembles_straddled_samples() {
        let original = StatsEvent::new(4242, core::time::Duration::from_nanos(9999), 6, 3);

        // SAFETY: StatsEvent has no implicit padding and every field is initialized.
        let bytes: [u8; 16] = unsafe { core::mem::transmute(original) };

        // The kernel pads samples to 8-byte alignment; emulate a padded record.
        let mut padded = [0_u8; 24];
        padded[..16].copy_from_slice(&bytes);

        for split in 0..=padded.len() {
            let (head, tail) = padded.split_at(split);

            let parsed = StatsEvent::from_chunks(head, tail).expect("chunks cover the sample");

            assert_eq!(parsed.ip_version(), original.ip_version());
            assert_eq!(parsed.ecn(), original.ecn());
            assert_eq!(parsed.relayed_data(), original.relayed_data());
            assert_eq!(
                parsed.processing_duration_ns,
                original.processing_duration_ns
            );
        }
    }

    #[test]
    fn from_chunks_rejects_a_truncated_sample() {
        let bytes = [0; core::mem::size_of::<StatsEvent>()];
        for len in 0..bytes.len() {
            assert!(StatsEvent::from_bytes(&bytes[..len]).is_none());
            for split in 0..=len {
                assert!(StatsEvent::from_chunks(&bytes[..split], &bytes[split..len]).is_none());
            }
        }
    }

    #[test]
    fn preserves_maximum_udp_packet_length() {
        let event = StatsEvent::new(u16::MAX, core::time::Duration::ZERO, 4, 3);
        // SAFETY: StatsEvent has no implicit padding and every field is initialized.
        let bytes: [u8; 16] = unsafe { core::mem::transmute(event) };
        assert_eq!(&bytes[..4], &u32::from(u16::MAX).to_ne_bytes());
        assert_eq!(
            StatsEvent::from_bytes(&bytes).unwrap().relayed_data(),
            u64::from(u16::MAX)
        );
    }

    #[test]
    fn stores_metadata_as_endian_independent_bytes() {
        for value in u8::MIN..=u8::MAX {
            let event = StatsEvent::new(0, core::time::Duration::ZERO, value, value);
            // SAFETY: StatsEvent has no implicit padding and every field is initialized.
            let bytes: [u8; 16] = unsafe { core::mem::transmute(event) };
            assert_eq!(bytes[4], value);
            assert_eq!(bytes[5], value);
            assert_eq!(&bytes[6..8], &[0; 2]);
            let parsed = StatsEvent::from_bytes(&bytes).unwrap();
            assert_eq!(parsed.ip_version(), value);
            assert_eq!(parsed.ecn(), value);
        }
    }

    #[test]
    fn preserves_each_ip_version_and_ecn_codepoint() {
        for ip_version in [4, 6] {
            for ecn in 0..=3 {
                let original =
                    StatsEvent::new(42, core::time::Duration::from_nanos(99), ip_version, ecn);
                // SAFETY: StatsEvent has no implicit padding and every field is initialized.
                let bytes: [u8; 16] = unsafe { core::mem::transmute(original) };
                let parsed = StatsEvent::from_bytes(&bytes).unwrap();
                assert_eq!(parsed.ip_version(), ip_version);
                assert_eq!(parsed.ecn(), ecn);
            }
        }
    }
}

#[cfg(all(feature = "std", target_os = "linux"))]
mod userspace {
    use super::*;

    unsafe impl aya::Pod for ClientAndChannelV4 {}

    unsafe impl aya::Pod for PortAndPeerV4 {}

    unsafe impl aya::Pod for ClientAndChannelV6 {}

    unsafe impl aya::Pod for PortAndPeerV6 {}
}
