use std::{
    collections::{BTreeMap, VecDeque},
    net::IpAddr,
};

use bufferpool::{Buffer, BufferPool};
use bytes::BytesMut;
use ip_packet::IpPacket;
use tun::IpPacketOut;

use super::MAX_INBOUND_PACKET_BATCH;

const MAX_SEGMENT_SIZE: usize = ip_packet::MAX_IP_SIZE;
const MAX_HEADER_SIZE: usize = 60 + 60; // Max IP header (60) + max TCP header (60)

/// Canonical header that groups packets for GSO batching.
/// This represents the IP + L4 header with variable fields normalized.
/// For TCP: sequence numbers, checksums are ignored
/// For UDP: length, checksums are ignored
#[derive(Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Clone)]
struct CanonicalHeader {
    /// The actual header bytes with variable fields zeroed out
    header_bytes: Vec<u8>,
    /// Length of the header (IP + L4)
    header_len: usize,
}

impl CanonicalHeader {
    /// Extract canonical header from an IP packet
    /// Returns None if the packet cannot be batched (not TCP/UDP, or parse failure)
    fn from_packet(packet: &IpPacket) -> Option<Self> {
        let packet_bytes = packet.packet();

        // Calculate IP header length
        let ip_header_len = if packet.source().is_ipv4() {
            (packet_bytes[0] & 0x0F) as usize * 4
        } else {
            40 // IPv6 header is always 40 bytes
        };

        // Only TCP and UDP can be batched
        if let Some(tcp) = packet.as_tcp() {
            // TCP packet - header is IP + TCP
            let tcp_header_len = (tcp.data_offset() as usize) * 4;
            let header_len = ip_header_len + tcp_header_len;

            if header_len > packet_bytes.len() {
                return None;
            }

            let mut header_bytes = vec![0u8; header_len];
            header_bytes.copy_from_slice(&packet_bytes[..header_len]);

            // Normalize variable fields in IP header
            if packet.source().is_ipv4() {
                header_bytes[2] = 0; // Total length
                header_bytes[3] = 0;
                header_bytes[10] = 0; // Checksum
                header_bytes[11] = 0;
            } else {
                header_bytes[4] = 0; // Payload length
                header_bytes[5] = 0;
            }

            // Zero out TCP sequence number and checksum
            let tcp_offset = ip_header_len;
            header_bytes[tcp_offset + 4] = 0; // Sequence number
            header_bytes[tcp_offset + 5] = 0;
            header_bytes[tcp_offset + 6] = 0;
            header_bytes[tcp_offset + 7] = 0;
            header_bytes[tcp_offset + 16] = 0; // Checksum
            header_bytes[tcp_offset + 17] = 0;

            return Some(CanonicalHeader {
                header_bytes,
                header_len,
            });
        }

        if let Some(_udp) = packet.as_udp() {
            // UDP packet - header is IP + UDP (8 bytes)
            let header_len = ip_header_len + 8;

            if header_len > packet_bytes.len() {
                return None;
            }

            let mut header_bytes = vec![0u8; header_len];
            header_bytes.copy_from_slice(&packet_bytes[..header_len]);

            // Normalize variable fields in IP header
            if packet.source().is_ipv4() {
                header_bytes[2] = 0; // Total length
                header_bytes[3] = 0;
                header_bytes[10] = 0; // Checksum
                header_bytes[11] = 0;
            } else {
                header_bytes[4] = 0; // Payload length
                header_bytes[5] = 0;
            }

            // Zero out UDP length and checksum
            let udp_offset = ip_header_len;
            header_bytes[udp_offset + 4] = 0; // Length
            header_bytes[udp_offset + 5] = 0;
            header_bytes[udp_offset + 6] = 0; // Checksum
            header_bytes[udp_offset + 7] = 0;

            return Some(CanonicalHeader {
                header_bytes,
                header_len,
            });
        }

        // Not TCP or UDP - cannot batch
        None
    }
}

/// A batch of payloads that can be sent with GSO
struct PayloadBatch {
    /// The size of each payload segment
    segment_size: usize,
    /// Concatenated payload bodies (without headers)
    payloads: Buffer<BytesMut>,
}

/// Holds IP packets that need to be sent, indexed by flow and segment size.
/// On Linux, packets are batched by flow for GSO. On other platforms, this
/// queue exists but is not used.
pub struct TunGsoQueue {
    /// Map from canonical header to batches of payloads
    inner: BTreeMap<CanonicalHeader, VecDeque<PayloadBatch>>,
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
        // Try to extract canonical header for batchable packets
        let canonical_header = CanonicalHeader::from_packet(packet).ok_or(NotBatchable)?;

        // Extract payload using the appropriate accessor
        let payload = if let Some(tcp) = packet.as_tcp() {
            tcp.payload()
        } else if let Some(udp) = packet.as_udp() {
            udp.payload()
        } else {
            return Err(NotBatchable);
        };

        let payload_len = payload.len();

        // Get or create batch list for this header
        let batches = self.inner.entry(canonical_header).or_default();

        // Check if we can append to existing batch
        let Some(batch) = batches.back_mut() else {
            // No existing batch, create new one
            let mut buffer = self.buffer_pool.pull();
            buffer.clear();
            buffer.extend_from_slice(payload);
            batches.push_back(PayloadBatch {
                segment_size: payload_len,
                payloads: buffer,
            });
            return Ok(());
        };

        // Check if payloads are being accumulated (buffer is multiple of segment_size)
        let batch_is_ongoing = batch.payloads.len() % batch.segment_size == 0;

        // Can only batch packets of same payload size
        if batch_is_ongoing && payload_len <= batch.segment_size {
            batch.payloads.extend_from_slice(payload);
            return Ok(());
        }

        // Different size, start new batch
        let mut buffer = self.buffer_pool.pull();
        buffer.clear();
        buffer.extend_from_slice(payload);
        batches.push_back(PayloadBatch {
            segment_size: payload_len,
            payloads: buffer,
        });

        Ok(())
    }

    pub fn packets(&mut self) -> impl Iterator<Item = IpPacketOut> + '_ {
        DrainPacketsIter { queue: self }
    }

    pub fn clear(&mut self) {
        self.inner.clear()
    }
}

struct DrainPacketsIter<'a> {
    queue: &'a mut TunGsoQueue,
}

impl Iterator for DrainPacketsIter<'_> {
    type Item = IpPacketOut;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            let mut entry = self.queue.inner.first_entry()?;

            // Clone the header data before borrowing mutably
            let header_bytes = entry.key().header_bytes.clone();
            let header_len = entry.key().header_len;

            let Some(batch) = entry.get_mut().pop_front() else {
                entry.remove();
                continue;
            };

            // Always return header and payloads separately
            // TUN device can handle batches of 1 just fine
            return Some(IpPacketOut {
                header: header_bytes,
                payloads: batch.payloads,
                segment_size: batch.segment_size,
            });
        }
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
        assert!(queue.packets().next().is_none());
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

        let mut iter = queue.packets();
        let out = iter.next().unwrap();

        assert!(out.is_gso());
        assert_eq!(out.segment_count(), 1);
        assert_eq!(&out.payloads[..], &[1, 2, 3, 4]);
        assert!(iter.next().is_none());
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

        let mut iter = queue.packets();
        let out = iter.next().unwrap();

        // Should be batched
        assert!(out.is_gso());
        assert_eq!(out.segment_count(), 2);

        // Verify payloads concatenated correctly
        assert_eq!(&out.payloads[0..4], &[1, 2, 3, 4]);
        assert_eq!(&out.payloads[4..8], &[5, 6, 7, 8]);

        assert!(iter.next().is_none());
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
            vec![5, 6, 7, 8, 9, 10],
        )
        .unwrap();

        queue.enqueue(&tcp1).unwrap();
        queue.enqueue(&tcp2).unwrap();

        // Should get two separate batches of 1
        let mut iter = queue.packets();
        let out1 = iter.next().unwrap();
        assert!(out1.is_gso());
        assert_eq!(out1.segment_count(), 1);

        let out2 = iter.next().unwrap();
        assert!(out2.is_gso());
        assert_eq!(out2.segment_count(), 1);

        assert!(iter.next().is_none());
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
            Ipv4Addr::new(192, 168, 1, 1),
            8080,
            8443, // Different port = different flow
            Default::default(),
            vec![5, 6, 7, 8],
        )
        .unwrap();

        queue.enqueue(&tcp1).unwrap();
        queue.enqueue(&tcp2).unwrap();

        // Should get two separate batches of 1
        let mut iter = queue.packets();
        let out1 = iter.next().unwrap();
        assert!(out1.is_gso());
        assert_eq!(out1.segment_count(), 1);

        let out2 = iter.next().unwrap();
        assert!(out2.is_gso());
        assert_eq!(out2.segment_count(), 1);

        assert!(iter.next().is_none());
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

        let mut iter = queue.packets();
        let out = iter.next().unwrap();

        assert!(out.is_gso());
        assert_eq!(out.segment_count(), 3);
        assert_eq!(&out.payloads[..], &[1, 2, 3, 4, 5, 6]);
        assert!(iter.next().is_none());
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

        let mut iter = queue.packets();
        let out = iter.next().unwrap();

        assert!(out.is_gso());
        assert_eq!(out.segment_count(), 2);
        assert!(iter.next().is_none());
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

        let mut iter = queue.packets();
        let out = iter.next().unwrap();

        assert!(out.is_gso());
        assert_eq!(out.segment_count(), 2);
        assert_eq!(&out.payloads[..], &[1, 2, 3, 4, 5, 6, 7, 8]);
        assert!(iter.next().is_none());
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

        assert!(queue.packets().next().is_none());
    }
}
