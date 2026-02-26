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

/// Key for grouping packets that can be coalesced via GSO
/// Only used for batchable packets (TCP/UDP with valid ports)
#[derive(Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Clone, Copy)]
struct FlowKey {
    src_addr: IpAddr, // Source IP
    dst_addr: IpAddr, // Destination IP
    src_port: u16,    // Source port
    dst_port: u16,    // Destination port
    protocol: u8,     // IP protocol number (6=TCP, 17=UDP)
}

/// Holds IP packets that need to be sent, indexed by flow and segment size.
/// On Linux, packets are batched by flow for GSO. On other platforms, this
/// queue exists but is not used.
pub struct TunGsoQueue {
    inner: BTreeMap<FlowKey, VecDeque<(usize, Buffer<BytesMut>)>>,
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
        let payload_len = packet.packet().len();
        let packet_bytes = packet.packet();

        // Try to extract flow key for batchable packets
        let key = extract_flow_key(packet).ok_or(NotBatchable)?;

        // Get or create batch for this flow
        let batches = self.inner.entry(key).or_default();

        // Check if we can append to existing batch
        let Some((batch_size, buffer)) = batches.back_mut() else {
            // No existing batch, create new one
            batches.push_back((payload_len, self.buffer_pool.pull_initialised(packet_bytes)));
            return Ok(());
        };

        let batch_size = *batch_size;
        let batch_is_ongoing = buffer.len() % batch_size == 0;

        // Can only batch packets of same size
        if batch_is_ongoing && payload_len <= batch_size {
            buffer.extend_from_slice(packet_bytes);
            return Ok(());
        }

        // Different size, start new batch
        batches.push_back((payload_len, self.buffer_pool.pull_initialised(packet_bytes)));

        Ok(())
    }

    pub fn packets(&mut self) -> impl Iterator<Item = IpPacketOut> + '_ {
        DrainPacketsIter { queue: self }
    }

    pub fn clear(&mut self) {
        self.inner.clear()
    }
}

/// Extract flow key from IP packet for batching
/// Returns Some for batchable packets (TCP/UDP with valid ports)
/// Returns None for non-batchable packets (ICMP, malformed TCP/UDP, etc.)
fn extract_flow_key(packet: &IpPacket) -> Option<FlowKey> {
    // Get source and destination IPs
    let src_addr = packet.source();
    let dst_addr = packet.destination();

    // Get protocol number
    let protocol = packet.next_header().0;

    // Extract ports for TCP/UDP only - other protocols are not batchable
    let (src_port, dst_port) = match protocol {
        6 => {
            // TCP
            let tcp = packet.as_tcp()?;
            (tcp.source_port(), tcp.destination_port())
        }
        17 => {
            // UDP
            let udp = packet.as_udp()?;
            (udp.source_port(), udp.destination_port())
        }
        _ => {
            // Other protocols (ICMP, ESP, etc.) - not batchable
            return None;
        }
    };

    Some(FlowKey {
        src_addr,
        dst_addr,
        src_port,
        dst_port,
        protocol,
    })
}

struct DrainPacketsIter<'a> {
    queue: &'a mut TunGsoQueue,
}

impl Iterator for DrainPacketsIter<'_> {
    type Item = IpPacketOut;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            let mut entry = self.queue.inner.first_entry()?;
            let Some((segment_size, buffer)) = entry.get_mut().pop_front() else {
                entry.remove();
                continue;
            };

            // If buffer contains only one segment, this is not a GSO batch
            let actual_segment_size = if buffer.len() == segment_size {
                0 // Single packet, no GSO
            } else {
                segment_size // Multiple segments, GSO batch
            };

            return Some(IpPacketOut {
                packet: buffer,
                segment_size: actual_segment_size,
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
    fn test_enqueue_icmp_returns_error() {
        let mut queue = TunGsoQueue::new();

        let packet = make::icmp_request_packet(
            Ipv4Addr::new(10, 0, 0, 1).into(),
            Ipv4Addr::new(8, 8, 8, 8),
            1,
            1,
            &[1, 2, 3, 4],
        )
        .unwrap();

        let result = queue.enqueue(&packet);

        assert!(result.is_err(), "ICMP should return NotBatchable error");

        // Verify no packets in iterator
        let mut packets = queue.packets();
        assert!(packets.next().is_none());
    }

    #[test]
    fn test_enqueue_tcp_succeeds() {
        let mut queue = TunGsoQueue::new();

        let packet = make::tcp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            8080,
            443,
            Default::default(),
            vec![1, 2, 3, 4],
        )
        .unwrap();

        let result = queue.enqueue(&packet);

        assert!(result.is_ok(), "TCP should be batchable");

        // Verify packet appears in iterator
        let mut packets = queue.packets();
        let out = packets.next().expect("Should have one packet");
        assert!(!out.is_gso(), "Single packet should not be GSO");
        assert_eq!(out.segment_count(), 1);
        assert!(packets.next().is_none());
    }

    #[test]
    fn test_same_size_tcp_packets_batch_together() {
        let mut queue = TunGsoQueue::new();

        // Add two TCP packets from same flow with same payload size
        let tcp1 = make::tcp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            8080,
            443,
            Default::default(),
            vec![1, 2, 3, 4],
        )
        .unwrap();
        let tcp1_len = tcp1.packet().len();

        let tcp2 = make::tcp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            8080,
            443,
            Default::default(),
            vec![5, 6, 7, 8],
        )
        .unwrap();
        let tcp2_len = tcp2.packet().len();

        queue.enqueue(&tcp1).unwrap();
        queue.enqueue(&tcp2).unwrap();

        // Should get one batched packet
        let mut packets = queue.packets();
        let out = packets.next().expect("Should have batched packet");
        assert!(out.is_gso(), "Should be GSO batch");
        assert_eq!(out.segment_count(), 2, "Should have 2 segments");
        assert_eq!(out.segment_size, tcp1_len);
        assert_eq!(out.total_len(), tcp1_len + tcp2_len);
        assert!(packets.next().is_none());
    }

    #[test]
    fn test_different_size_packets_dont_batch() {
        let mut queue = TunGsoQueue::new();

        // Add two TCP packets from same flow with different payload sizes
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
            vec![5, 6, 7, 8, 9, 10], // Different size
        )
        .unwrap();

        queue.enqueue(&tcp1).unwrap();
        queue.enqueue(&tcp2).unwrap();

        // Should get two separate packets
        let mut packets = queue.packets();
        let out1 = packets.next().expect("Should have first packet");
        assert!(!out1.is_gso(), "Different sizes shouldn't batch");
        assert_eq!(out1.segment_count(), 1);

        let out2 = packets.next().expect("Should have second packet");
        assert!(!out2.is_gso(), "Different sizes shouldn't batch");
        assert_eq!(out2.segment_count(), 1);

        assert!(packets.next().is_none());
    }

    #[test]
    fn test_different_flows_dont_batch() {
        let mut queue = TunGsoQueue::new();

        // Same size but different destination port
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
            8443, // Different port
            Default::default(),
            vec![5, 6, 7, 8],
        )
        .unwrap();

        queue.enqueue(&tcp1).unwrap();
        queue.enqueue(&tcp2).unwrap();

        // Should get two separate packets (different flows)
        let mut packets = queue.packets();
        let out1 = packets.next().expect("Should have first packet");
        assert!(!out1.is_gso(), "Different flows shouldn't batch");

        let out2 = packets.next().expect("Should have second packet");
        assert!(!out2.is_gso(), "Different flows shouldn't batch");

        assert!(packets.next().is_none());
    }

    #[test]
    fn test_ipv6_tcp_can_batch() {
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

        let mut packets = queue.packets();
        let out = packets.next().expect("Should have batched packet");
        assert!(out.is_gso(), "IPv6 TCP should batch");
        assert_eq!(out.segment_count(), 2);
        assert!(packets.next().is_none());
    }

    #[test]
    fn test_clear_empties_queue() {
        let mut queue = TunGsoQueue::new();

        let packet = make::tcp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            8080,
            443,
            Default::default(),
            vec![1, 2, 3, 4],
        )
        .unwrap();

        queue.enqueue(&packet).unwrap();
        queue.clear();

        let mut packets = queue.packets();
        assert!(packets.next().is_none());
    }
}
