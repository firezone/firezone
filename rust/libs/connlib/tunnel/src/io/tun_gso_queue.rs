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
    /// Queue for non-batchable packets (ICMP, malformed TCP/UDP, etc.)
    /// These are sent individually with segment_size = 0
    non_batchable: VecDeque<Buffer<BytesMut>>,
    buffer_pool: BufferPool<BytesMut>,
}

impl TunGsoQueue {
    pub fn new() -> Self {
        Self {
            inner: Default::default(),
            buffer_pool: BufferPool::new(
                MAX_SEGMENT_SIZE * MAX_INBOUND_PACKET_BATCH,
                "tun-gso-queue",
            ),
            non_batchable: VecDeque::new(),
        }
    }

    pub fn enqueue(&mut self, packet: IpPacket) {
        let payload_len = packet.packet().len();
        let packet_bytes = packet.packet();

        // Try to extract flow key for batchable packets
        let Some(key) = extract_flow_key(&packet) else {
            // Not batchable (ICMP, malformed TCP/UDP, etc.) - queue separately
            self.non_batchable
                .push_back(self.buffer_pool.pull_initialised(packet_bytes));
            return;
        };

        // Get or create batch for this flow
        let batches = self.inner.entry(key).or_default();

        // Check if we can append to existing batch
        let Some((batch_size, buffer)) = batches.back_mut() else {
            // No existing batch, create new one
            batches.push_back((payload_len, self.buffer_pool.pull_initialised(packet_bytes)));
            return;
        };

        let batch_size = *batch_size;
        let batch_is_ongoing = buffer.len() % batch_size == 0;

        // Can only batch packets of same size
        if batch_is_ongoing && payload_len <= batch_size {
            buffer.extend_from_slice(packet_bytes);
            return;
        }

        // Different size, start new batch
        batches.push_back((payload_len, self.buffer_pool.pull_initialised(packet_bytes)));
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
        // First, drain non-batchable packets
        if let Some(buffer) = self.queue.non_batchable.pop_front() {
            return Some(IpPacketOut {
                packet: buffer,
                segment_size: 0, // Single packet, no GSO
            });
        }

        // Then drain batchable packets
        loop {
            let mut entry = self.queue.inner.first_entry()?;
            let Some((segment_size, buffer)) = entry.get_mut().pop_front() else {
                entry.remove();
                continue;
            };

            return Some(IpPacketOut {
                packet: buffer,
                segment_size,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ip_packet::make;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    #[test]
    fn test_extract_flow_key_tcp() {
        let packet = make::tcp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            8080,
            443,
            Default::default(),
            vec![1, 2, 3, 4],
        )
        .unwrap();

        let key = extract_flow_key(&packet).expect("Should extract TCP flow key");

        assert_eq!(key.src_addr, IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)));
        assert_eq!(key.dst_addr, IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1)));
        assert_eq!(key.src_port, 8080);
        assert_eq!(key.dst_port, 443);
        assert_eq!(key.protocol, 6); // TCP
    }

    #[test]
    fn test_extract_flow_key_udp() {
        let packet = make::udp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            5353,
            53,
            vec![1, 2, 3, 4],
        )
        .unwrap();

        let key = extract_flow_key(&packet).expect("Should extract UDP flow key");

        assert_eq!(key.src_addr, IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)));
        assert_eq!(key.dst_addr, IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1)));
        assert_eq!(key.src_port, 5353);
        assert_eq!(key.dst_port, 53);
        assert_eq!(key.protocol, 17); // UDP
    }

    #[test]
    fn test_extract_flow_key_icmp_returns_none() {
        let packet = make::icmp_request_packet(
            Ipv4Addr::new(10, 0, 0, 1).into(),
            Ipv4Addr::new(8, 8, 8, 8),
            1,
            1,
            &[1, 2, 3, 4],
        )
        .unwrap();

        let key = extract_flow_key(&packet);

        assert!(key.is_none(), "ICMP packets should not be batchable");
    }

    #[test]
    fn test_enqueue_icmp_goes_to_non_batchable() {
        let mut queue = TunGsoQueue::new();

        let packet = make::icmp_request_packet(
            Ipv4Addr::new(10, 0, 0, 1).into(),
            Ipv4Addr::new(8, 8, 8, 8),
            1,
            1,
            &[1, 2, 3, 4],
        )
        .unwrap();

        queue.enqueue(packet);

        assert_eq!(queue.non_batchable.len(), 1);
        assert_eq!(queue.inner.len(), 0);
    }

    #[test]
    fn test_enqueue_tcp_goes_to_batchable() {
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

        queue.enqueue(packet);

        assert_eq!(queue.non_batchable.len(), 0);
        assert_eq!(queue.inner.len(), 1);
    }

    #[test]
    fn test_drain_non_batchable_first() {
        let mut queue = TunGsoQueue::new();

        // Add ICMP packet (non-batchable)
        let icmp = make::icmp_request_packet(
            Ipv4Addr::new(10, 0, 0, 1).into(),
            Ipv4Addr::new(8, 8, 8, 8),
            1,
            1,
            &[1, 2, 3],
        )
        .unwrap();

        // Add TCP packet (batchable)
        let tcp = make::tcp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(192, 168, 1, 1),
            8080,
            443,
            Default::default(),
            vec![4, 5, 6],
        )
        .unwrap();

        queue.enqueue(icmp);
        queue.enqueue(tcp);

        let mut iter = queue.packets();
        let first = iter.next().expect("Should have first packet");

        // Non-batchable packet should come first and have segment_size = 0
        assert_eq!(first.segment_size, 0);
    }

    #[test]
    fn test_ipv6_tcp_flow_key() {
        let packet = make::tcp_packet(
            Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1),
            Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 2),
            8080,
            443,
            Default::default(),
            vec![1, 2, 3, 4],
        )
        .unwrap();

        let key = extract_flow_key(&packet).expect("Should extract IPv6 TCP flow key");

        assert_eq!(
            key.src_addr,
            IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1))
        );
        assert_eq!(
            key.dst_addr,
            IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 2))
        );
        assert_eq!(key.src_port, 8080);
        assert_eq!(key.dst_port, 443);
        assert_eq!(key.protocol, 6);
    }
}
