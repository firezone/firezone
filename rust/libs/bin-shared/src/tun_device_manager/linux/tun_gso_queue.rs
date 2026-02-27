use std::collections::{BTreeMap, VecDeque};

use bufferpool::{Buffer, BufferPool};
use bytes::BytesMut;
use ip_packet::IpPacket;

const MAX_INBOUND_PACKET_BATCH: usize = 32;
const MAX_SEGMENT_SIZE: usize = ip_packet::MAX_IP_SIZE;

// GSO type constants for virtio_net_hdr
const VIRTIO_NET_HDR_GSO_TCPV4: u8 = 1;
const VIRTIO_NET_HDR_GSO_TCPV6: u8 = 4;
const VIRTIO_NET_HDR_GSO_UDP_L4: u8 = 5;

/// A batch of IP packets ready to be sent with GSO
#[derive(Debug)]
pub struct IpPacketBatch {
    /// Serialized header bytes (IP + L4 header)
    header: Vec<u8>,
    /// Concatenated payload bodies (without headers)
    payloads: Buffer<BytesMut>,
    /// Size of each payload segment
    segment_size: usize,
    /// Metadata for constructing virtio header
    metadata: GsoMetadata,
}

/// Metadata needed to construct a virtio_net_hdr for GSO
#[derive(Debug, Clone, Copy)]
pub struct GsoMetadata {
    /// GSO type (VIRTIO_NET_HDR_GSO_TCPV4, etc.)
    pub gso_type: u8,
    /// Total header length (IP + L4)
    pub header_len: u16,
    /// Where checksumming starts (typically IP header length)
    pub csum_start: u16,
    /// Offset within L4 header for checksum field
    pub csum_offset: u16,
}

impl IpPacketBatch {
    /// Get the serialized header bytes
    pub fn header_bytes(&self) -> &[u8] {
        &self.header
    }

    /// Get the payload bytes
    pub fn payload_bytes(&self) -> &[u8] {
        &self.payloads
    }

    /// Get the segment size
    pub fn segment_size(&self) -> usize {
        self.segment_size
    }

    /// Get the GSO metadata
    pub fn metadata(&self) -> &GsoMetadata {
        &self.metadata
    }

    /// Returns the number of segments in this batch
    #[cfg(test)]
    pub fn segment_count(&self) -> usize {
        self.payloads.len() / self.segment_size
    }
}

/// Extract GSO metadata from packet headers
fn extract_metadata(packet: &IpPacket) -> Option<GsoMetadata> {
    match (
        packet.ipv4_header(),
        packet.ipv6_header(),
        packet.as_tcp(),
        packet.as_udp(),
    ) {
        // IPv4 + TCP
        (Some(ipv4), None, Some(tcp), None) => {
            let ip_header_len = ipv4.header_len() as u16;
            let tcp_header_len = tcp.data_offset() as u16 * 4;
            Some(GsoMetadata {
                gso_type: VIRTIO_NET_HDR_GSO_TCPV4,
                header_len: ip_header_len + tcp_header_len,
                csum_start: ip_header_len,
                csum_offset: 16, // TCP checksum at offset 16
            })
        }
        // IPv6 + TCP
        (None, Some(_ipv6), Some(tcp), None) => {
            let ip_header_len = 40u16; // IPv6 header is always 40 bytes
            let tcp_header_len = tcp.data_offset() as u16 * 4;
            Some(GsoMetadata {
                gso_type: VIRTIO_NET_HDR_GSO_TCPV6,
                header_len: ip_header_len + tcp_header_len,
                csum_start: ip_header_len,
                csum_offset: 16, // TCP checksum at offset 16
            })
        }
        // IPv4 + UDP
        (Some(ipv4), None, None, Some(_udp)) => {
            let ip_header_len = ipv4.header_len() as u16;
            let udp_header_len = 8u16; // UDP header is always 8 bytes
            Some(GsoMetadata {
                gso_type: VIRTIO_NET_HDR_GSO_UDP_L4,
                header_len: ip_header_len + udp_header_len,
                csum_start: ip_header_len,
                csum_offset: 6, // UDP checksum at offset 6
            })
        }
        // IPv6 + UDP
        (None, Some(_ipv6), None, Some(_udp)) => {
            let ip_header_len = 40u16; // IPv6 header is always 40 bytes
            let udp_header_len = 8u16; // UDP header is always 8 bytes
            Some(GsoMetadata {
                gso_type: VIRTIO_NET_HDR_GSO_UDP_L4,
                header_len: ip_header_len + udp_header_len,
                csum_start: ip_header_len,
                csum_offset: 6, // UDP checksum at offset 6
            })
        }
        // Everything else (ICMP, malformed packets, etc.) cannot be batched
        _ => None,
    }
}

/// Extract canonical header bytes for batching (with variable fields zeroed)
fn extract_canonical_header(packet: &IpPacket, metadata: &GsoMetadata) -> Option<Vec<u8>> {
    let header_len = metadata.header_len as usize;
    let packet_bytes = packet.packet();

    if packet_bytes.len() < header_len {
        return None;
    }

    let mut header = packet_bytes[..header_len].to_vec();

    // Zero out variable fields based on protocol
    match metadata.gso_type {
        VIRTIO_NET_HDR_GSO_TCPV4 => {
            // IPv4: zero total length (bytes 2-3) and checksum (bytes 10-11)
            header[2..4].fill(0);
            header[10..12].fill(0);
            // TCP: zero sequence number (bytes 4-7 from TCP start) and checksum (bytes 16-17)
            let tcp_offset = (header[0] & 0x0F) as usize * 4;
            if tcp_offset + 18 <= header.len() {
                header[tcp_offset + 4..tcp_offset + 8].fill(0);
                header[tcp_offset + 16..tcp_offset + 18].fill(0);
            }
        }
        VIRTIO_NET_HDR_GSO_TCPV6 => {
            // IPv6: zero payload length (bytes 4-5)
            header[4..6].fill(0);
            // TCP: zero sequence number and checksum (40 bytes into packet)
            if header.len() >= 58 {
                header[44..48].fill(0); // sequence number
                header[56..58].fill(0); // checksum
            }
        }
        VIRTIO_NET_HDR_GSO_UDP_L4 if metadata.gso_type == VIRTIO_NET_HDR_GSO_UDP_L4 => {
            if packet.ipv4_header().is_some() {
                // IPv4: zero total length and checksum
                header[2..4].fill(0);
                header[10..12].fill(0);
                // UDP: zero length (bytes 4-5) and checksum (bytes 6-7)
                let udp_offset = (header[0] & 0x0F) as usize * 4;
                if udp_offset + 8 <= header.len() {
                    header[udp_offset + 4..udp_offset + 6].fill(0);
                    header[udp_offset + 6..udp_offset + 8].fill(0);
                }
            } else {
                // IPv6: zero payload length
                header[4..6].fill(0);
                // UDP: zero length and checksum (40 bytes into packet)
                if header.len() >= 48 {
                    header[44..46].fill(0); // length
                    header[46..48].fill(0); // checksum
                }
            }
        }
        _ => return None,
    }

    Some(header)
}

/// Holds IP packets that need to be sent, indexed by flow and segment size.
/// Packets are batched by flow for GSO.
pub struct TunGsoQueue {
    /// Map from canonical header bytes to batches of payloads
    inner: BTreeMap<Vec<u8>, VecDeque<IpPacketBatch>>,
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
        // Extract metadata
        let metadata = extract_metadata(packet).ok_or(NotBatchable)?;

        // Extract canonical header for map key
        let canonical_key = extract_canonical_header(packet, &metadata).ok_or(NotBatchable)?;

        // Extract actual header bytes for this packet
        let header_len = metadata.header_len as usize;
        let header = packet.packet()[..header_len].to_vec();

        // Extract payload
        let payload = if let Some(tcp) = packet.as_tcp() {
            tcp.payload()
        } else if let Some(udp) = packet.as_udp() {
            udp.payload()
        } else {
            return Err(NotBatchable);
        };

        let payload_len = payload.len();

        // Get or create batch list for this flow
        let batches = self.inner.entry(canonical_key).or_default();

        // Check if we can append to existing batch
        if let Some(batch) = batches.back_mut() {
            // Check if payloads are being accumulated (buffer is multiple of segment_size)
            let batch_is_ongoing = batch.payloads.len() % batch.segment_size == 0;

            // Can only batch packets of same or smaller payload size (last segment can be smaller)
            if batch_is_ongoing && payload_len <= batch.segment_size {
                batch.payloads.extend_from_slice(payload);
                return Ok(());
            }
        }

        // Start new batch
        let mut buffer = self.buffer_pool.pull();
        buffer.clear();
        buffer.extend_from_slice(payload);

        batches.push_back(IpPacketBatch {
            header,
            payloads: buffer,
            segment_size: payload_len,
            metadata,
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
        assert_eq!(batches[0].segment_count(), 1); // Only counts full segments
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
