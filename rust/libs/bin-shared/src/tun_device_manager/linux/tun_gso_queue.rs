use std::collections::{BTreeMap, VecDeque};

use bufferpool::{Buffer, BufferPool};
use bytes::BytesMut;
use ip_packet::IpPacket;

const MAX_INBOUND_PACKET_BATCH: usize = 32;
const MAX_SEGMENT_SIZE: usize = ip_packet::MAX_IP_SIZE;

/// Size of virtio_net_hdr_v1
const VIRTIO_NET_HDR_SIZE: usize = 12;

// GSO type constants for virtio_net_hdr
const VIRTIO_NET_HDR_GSO_TCPV4: u8 = 1;
const VIRTIO_NET_HDR_GSO_TCPV6: u8 = 4;
const VIRTIO_NET_HDR_GSO_UDP_L4: u8 = 5;

/// A batch of IP packets ready to be sent with GSO
#[derive(Debug)]
pub struct IpPacketBatch {
    /// Pre-built virtio_net_hdr (12 bytes)
    pub vnet_hdr: [u8; VIRTIO_NET_HDR_SIZE],
    /// Canonical header (parsed, with variable fields zeroed)
    pub header: GsoHeader,
    /// Concatenated payload bodies (without headers)
    pub payloads: Buffer<BytesMut>,
    /// Size of each payload segment
    pub segment_size: usize,
}

/// Parsed header info needed for GSO batching (with variable fields zeroed)
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GsoHeader {
    Ipv4Tcp {
        ipv4: ip_packet::Ipv4Header,
        tcp: ip_packet::TcpHeader,
    },
    Ipv6Tcp {
        ipv6: ip_packet::Ipv6Header,
        tcp: ip_packet::TcpHeader,
    },
    Ipv4Udp {
        ipv4: ip_packet::Ipv4Header,
        udp: ip_packet::UdpHeader,
    },
    Ipv6Udp {
        ipv6: ip_packet::Ipv6Header,
        udp: ip_packet::UdpHeader,
    },
}

impl GsoHeader {
    /// Parse from packet and zero out variable fields
    fn from_packet(packet: &IpPacket) -> Option<Self> {
        match (
            packet.ipv4_header(),
            packet.ipv6_header(),
            packet.as_tcp(),
            packet.as_udp(),
        ) {
            (Some(ipv4), None, Some(tcp), None) => Some(Self::Ipv4Tcp {
                ipv4: ip_packet::Ipv4Header {
                    total_len: 0,       // Variable: zeroed for canonical form
                    header_checksum: 0, // Variable: zeroed for canonical form
                    ..ipv4
                },
                tcp: ip_packet::TcpHeader {
                    sequence_number: 0, // Variable: zeroed for canonical form
                    checksum: 0,        // Variable: zeroed for canonical form
                    ..tcp.to_header()
                },
            }),
            (None, Some(ipv6), Some(tcp), None) => Some(Self::Ipv6Tcp {
                ipv6: ip_packet::Ipv6Header {
                    payload_length: 0, // Variable: zeroed for canonical form
                    ..ipv6
                },
                tcp: ip_packet::TcpHeader {
                    sequence_number: 0, // Variable: zeroed for canonical form
                    checksum: 0,        // Variable: zeroed for canonical form
                    ..tcp.to_header()
                },
            }),
            (Some(ipv4), None, None, Some(udp)) => Some(Self::Ipv4Udp {
                ipv4: ip_packet::Ipv4Header {
                    total_len: 0,       // Variable: zeroed for canonical form
                    header_checksum: 0, // Variable: zeroed for canonical form
                    ..ipv4
                },
                udp: ip_packet::UdpHeader {
                    length: 0,   // Variable: zeroed for canonical form
                    checksum: 0, // Variable: zeroed for canonical form
                    ..udp.to_header()
                },
            }),
            (None, Some(ipv6), None, Some(udp)) => Some(Self::Ipv6Udp {
                ipv6: ip_packet::Ipv6Header {
                    payload_length: 0, // Variable: zeroed for canonical form
                    ..ipv6
                },
                udp: ip_packet::UdpHeader {
                    length: 0,   // Variable: zeroed for canonical form
                    checksum: 0, // Variable: zeroed for canonical form
                    ..udp.to_header()
                },
            }),
            _ => None,
        }
    }

    /// Get GSO type for virtio header
    fn gso_type(&self) -> u8 {
        match self {
            Self::Ipv4Tcp { .. } => VIRTIO_NET_HDR_GSO_TCPV4,
            Self::Ipv6Tcp { .. } => VIRTIO_NET_HDR_GSO_TCPV6,
            Self::Ipv4Udp { .. } | Self::Ipv6Udp { .. } => VIRTIO_NET_HDR_GSO_UDP_L4,
        }
    }

    /// Get header length
    fn header_len(&self) -> u16 {
        match self {
            Self::Ipv4Tcp { ipv4, tcp } => ipv4.header_len() as u16 + tcp.data_offset() as u16 * 4,
            Self::Ipv6Tcp { tcp, .. } => 40 + tcp.data_offset() as u16 * 4,
            Self::Ipv4Udp { ipv4, .. } => ipv4.header_len() as u16 + 8,
            Self::Ipv6Udp { .. } => 40 + 8,
        }
    }

    /// Get checksum start offset
    fn csum_start(&self) -> u16 {
        match self {
            Self::Ipv4Tcp { ipv4, .. } | Self::Ipv4Udp { ipv4, .. } => ipv4.header_len() as u16,
            Self::Ipv6Tcp { .. } | Self::Ipv6Udp { .. } => 40,
        }
    }

    /// Get checksum offset within L4 header
    fn csum_offset(&self) -> u16 {
        match self {
            Self::Ipv4Tcp { .. } | Self::Ipv6Tcp { .. } => 16, // TCP checksum
            Self::Ipv4Udp { .. } | Self::Ipv6Udp { .. } => 6,  // UDP checksum
        }
    }
}

/// Build virtio_net_hdr from GSO info
fn build_vnet_hdr(header: &GsoHeader, segment_size: u16) -> [u8; VIRTIO_NET_HDR_SIZE] {
    let mut vnet_hdr = [0u8; VIRTIO_NET_HDR_SIZE];

    vnet_hdr[0] = 1; // VIRTIO_NET_HDR_F_NEEDS_CSUM
    vnet_hdr[1] = header.gso_type();
    vnet_hdr[2..4].copy_from_slice(&header.header_len().to_le_bytes());
    vnet_hdr[4..6].copy_from_slice(&segment_size.to_le_bytes());
    vnet_hdr[6..8].copy_from_slice(&header.csum_start().to_le_bytes());
    vnet_hdr[8..10].copy_from_slice(&header.csum_offset().to_le_bytes());
    vnet_hdr[10..12].copy_from_slice(&0u16.to_le_bytes());

    vnet_hdr
}

/// Holds IP packets that need to be sent, indexed by flow.
/// Packets are batched by flow for GSO.
pub struct TunGsoQueue {
    /// Map from canonical header to batches of payloads
    inner: BTreeMap<GsoHeader, VecDeque<IpPacketBatch>>,
    buffer_pool: BufferPool<BytesMut>,
}

/// Error returned when a packet cannot be batched
#[derive(Debug)]
pub struct NotBatchable;

impl TunGsoQueue {
    pub fn new() -> Self {
        Self {
            inner: Default::default(),
            buffer_pool: BufferPool::new(
                MAX_SEGMENT_SIZE * MAX_INBOUND_PACKET_BATCH,
                "tun-gso-queue",
            ),
        }
    }

    /// Enqueue a packet for batching.
    /// Returns Err(NotBatchable) if the packet cannot be batched (ICMP, malformed TCP/UDP, etc.)
    pub fn enqueue(&mut self, packet: &IpPacket) -> Result<(), NotBatchable> {
        // Parse header (already has variable fields zeroed)
        let header = GsoHeader::from_packet(packet).ok_or(NotBatchable)?;

        // Extract payload
        let payload = if let Some(tcp) = packet.as_tcp() {
            tcp.payload()
        } else if let Some(udp) = packet.as_udp() {
            udp.payload()
        } else {
            return Err(NotBatchable);
        };

        let payload_len = payload.len();

        // Get or create batch list for this flow (use header as key)
        let batches = self.inner.entry(header.clone()).or_default();

        // Check if we can append to existing batch
        if let Some(batch) = batches.back_mut() {
            let batch_is_ongoing = batch.payloads.len() % batch.segment_size == 0;

            // Can batch packets of same or smaller payload size (last segment can be smaller)
            if batch_is_ongoing && payload_len <= batch.segment_size {
                batch.payloads.extend_from_slice(payload);
                return Ok(());
            }
        }

        // Start new batch - build vnet header immediately
        let mut buffer = self.buffer_pool.pull();
        buffer.clear();
        buffer.extend_from_slice(payload);

        let vnet_hdr = build_vnet_hdr(&header, payload_len as u16);

        batches.push_back(IpPacketBatch {
            vnet_hdr,
            header,
            payloads: buffer,
            segment_size: payload_len,
        });

        Ok(())
    }

    /// Drain all batches from the queue
    pub fn packets(&mut self) -> impl Iterator<Item = IpPacketBatch> + '_ {
        DrainPacketsIter { queue: self }
    }

    pub fn clear(&mut self) {
        self.inner.clear();
    }
}

struct DrainPacketsIter<'a> {
    queue: &'a mut TunGsoQueue,
}

impl Iterator for DrainPacketsIter<'_> {
    type Item = IpPacketBatch;

    fn next(&mut self) -> Option<Self::Item> {
        // Iterate over all flows
        while let Some(mut entry) = self.queue.inner.first_entry() {
            let batches = entry.get_mut();

            // Pop the first batch from this flow
            if let Some(batch) = batches.pop_front() {
                // If no more batches for this flow, remove the entry
                if batches.is_empty() {
                    entry.remove();
                }

                return Some(batch);
            }

            // No batches left for this flow, remove it
            entry.remove();
        }

        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ip_packet::make;
    use std::net::{Ipv4Addr, Ipv6Addr};

    #[test]
    fn icmp_returns_error() {
        let mut queue = TunGsoQueue::new();

        let icmp = make::icmp_request_packet(
            Ipv4Addr::new(10, 0, 0, 1).into(),
            Ipv4Addr::new(8, 8, 8, 8),
            1,
            1,
            &[1, 2, 3, 4],
        )
        .unwrap();

        assert!(queue.enqueue(&icmp).is_err());
    }

    #[test]
    fn single_tcp_packet_is_batch_of_one() {
        let mut queue = TunGsoQueue::new();

        let tcp = make::tcp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            8080,
            443,
            Default::default(),
            vec![1, 2, 3, 4],
        )
        .unwrap();

        queue.enqueue(&tcp).unwrap();

        let batches = queue.packets().collect::<Vec<_>>();
        assert_eq!(batches.len(), 1);
        assert_eq!(batches[0].segment_count(), 1);
        assert_eq!(batches[0].segment_size(), 4);
    }

    #[test]
    fn same_flow_same_size_batches() {
        let mut queue = TunGsoQueue::new();

        let tcp1 = make::tcp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            8080,
            443,
            Default::default(),
            vec![1, 2, 3, 4],
        )
        .unwrap();
        let tcp2 = make::tcp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            8080,
            443,
            Default::default(),
            vec![5, 6, 7, 8],
        )
        .unwrap();

        queue.enqueue(&tcp1).unwrap();
        queue.enqueue(&tcp2).unwrap();

        let batches = queue.packets().collect::<Vec<_>>();
        assert_eq!(batches.len(), 1);
        assert_eq!(batches[0].segment_count(), 2);
        assert_eq!(batches[0].segment_size(), 4);
        assert_eq!(batches[0].payload_bytes(), &[1, 2, 3, 4, 5, 6, 7, 8]);
    }

    #[test]
    fn different_size_creates_separate_batches() {
        let mut queue = TunGsoQueue::new();

        let tcp1 = make::tcp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            8080,
            443,
            Default::default(),
            vec![1, 2, 3, 4],
        )
        .unwrap();
        let tcp2 = make::tcp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            8080,
            443,
            Default::default(),
            vec![5, 6],
        )
        .unwrap();

        queue.enqueue(&tcp1).unwrap();
        queue.enqueue(&tcp2).unwrap();

        // Smaller packet is allowed as the last segment in a batch
        let batches = queue.packets().collect::<Vec<_>>();
        assert_eq!(batches.len(), 1);
        assert_eq!(batches[0].segment_count(), 1);
        assert_eq!(batches[0].segment_size(), 4);
        // Total payload is 4 + 2 = 6 bytes
        assert_eq!(batches[0].payload_bytes().len(), 6);
    }

    #[test]
    fn different_flow_creates_separate_batches() {
        let mut queue = TunGsoQueue::new();

        let tcp1 = make::tcp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            8080,
            443,
            Default::default(),
            vec![1, 2, 3, 4],
        )
        .unwrap();
        let tcp2 = make::tcp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 2), // Different destination
            8080,
            443,
            Default::default(),
            vec![5, 6, 7, 8],
        )
        .unwrap();

        queue.enqueue(&tcp1).unwrap();
        queue.enqueue(&tcp2).unwrap();

        let batches = queue.packets().collect::<Vec<_>>();
        assert_eq!(batches.len(), 2);
    }

    #[test]
    fn udp_same_flow_batches() {
        let mut queue = TunGsoQueue::new();

        let udp1 = make::udp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            5000,
            53,
            vec![1, 2, 3, 4],
        )
        .unwrap();
        let udp2 = make::udp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            5000,
            53,
            vec![5, 6, 7, 8],
        )
        .unwrap();

        queue.enqueue(&udp1).unwrap();
        queue.enqueue(&udp2).unwrap();

        let batches = queue.packets().collect::<Vec<_>>();
        assert_eq!(batches.len(), 1);
        assert_eq!(batches[0].segment_count(), 2);
    }

    #[test]
    fn clear_empties_queue() {
        let mut queue = TunGsoQueue::new();

        let tcp = make::tcp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            8080,
            443,
            Default::default(),
            vec![1, 2, 3, 4],
        )
        .unwrap();
        queue.enqueue(&tcp).unwrap();

        queue.clear();
        let batches = queue.packets().collect::<Vec<_>>();
        assert_eq!(batches.len(), 0);
    }

    #[test]
    fn three_packets_same_size_batch_together() {
        let mut queue = TunGsoQueue::new();

        for payload in [[1, 2], [3, 4], [5, 6]] {
            let tcp = make::tcp_packet(
                Ipv4Addr::new(10, 0, 0, 1),
                Ipv4Addr::new(192, 168, 1, 1),
                8080,
                443,
                Default::default(),
                payload.to_vec(),
            )
            .unwrap();
            queue.enqueue(&tcp).unwrap();
        }

        let batches = queue.packets().collect::<Vec<_>>();
        assert_eq!(batches.len(), 1);
        assert_eq!(batches[0].segment_count(), 3);
        assert_eq!(batches[0].payload_bytes(), &[1, 2, 3, 4, 5, 6]);
    }

    #[test]
    fn ipv6_tcp_batches() {
        let mut queue = TunGsoQueue::new();

        let tcp1 = make::tcp_packet(
            Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1),
            Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 2),
            8080,
            443,
            Default::default(),
            vec![1, 2, 3, 4],
        )
        .unwrap();
        let tcp2 = make::tcp_packet(
            Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1),
            Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 2),
            8080,
            443,
            Default::default(),
            vec![5, 6, 7, 8],
        )
        .unwrap();

        queue.enqueue(&tcp1).unwrap();
        queue.enqueue(&tcp2).unwrap();

        let batches = queue.packets().collect::<Vec<_>>();
        assert_eq!(batches.len(), 1);
        assert_eq!(batches[0].segment_count(), 2);
    }
}
