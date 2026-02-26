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
#[derive(Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Clone, Copy)]
struct FlowKey {
    src_addr: IpAddr, // Source IP
    dst_addr: IpAddr, // Destination IP
    src_port: u16,    // Source port (0 for non-TCP/UDP)
    dst_port: u16,    // Destination port (0 for non-TCP/UDP)
    protocol: u8,     // IP protocol number (6=TCP, 17=UDP)
}

/// Holds IP packets that need to be sent, indexed by flow and segment size.
/// On Linux, packets are batched by flow for GSO. On other platforms, this
/// queue exists but is not used.
pub struct TunGsoQueue {
    inner: BTreeMap<FlowKey, VecDeque<(usize, Buffer<BytesMut>)>>,
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
        }
    }

    pub fn enqueue(&mut self, packet: IpPacket) {
        let payload_len = packet.packet().len();
        let packet_bytes = packet.packet();

        // Extract flow key - this works for all protocols (TCP/UDP/ICMP/etc)
        let key = extract_flow_key(&packet);

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
/// Always returns a key so all packets can be sent, even if they can't be batched effectively.
fn extract_flow_key(packet: &IpPacket) -> FlowKey {
    // Get source and destination IPs
    let src_addr = packet.source();
    let dst_addr = packet.destination();

    // Get protocol number
    let protocol = packet.next_header().0;

    // Extract ports for TCP/UDP, use 0 for other protocols
    // For protocols where parsing fails (malformed packets), we still return a key
    // with ports = 0 so the packet can be sent (just not batched effectively)
    let (src_port, dst_port) = match protocol {
        6 => {
            // TCP
            if let Some(tcp) = packet.as_tcp() {
                (tcp.source_port(), tcp.destination_port())
            } else {
                tracing::debug!("Failed to parse TCP packet, sending without port info");
                (0, 0)
            }
        }
        17 => {
            // UDP
            if let Some(udp) = packet.as_udp() {
                (udp.source_port(), udp.destination_port())
            } else {
                tracing::debug!("Failed to parse UDP packet, sending without port info");
                (0, 0)
            }
        }
        _ => {
            // Other protocols (ICMP, ESP, etc.) - no ports
            (0, 0)
        }
    };

    FlowKey {
        src_addr,
        dst_addr,
        src_port,
        dst_port,
        protocol,
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
    use std::net::{IpAddr, Ipv4Addr};

    #[test]
    fn test_flow_key_different_for_different_ips() {
        // Verify that FlowKey correctly distinguishes different IPs
        let key1 = FlowKey {
            src_addr: IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)),
            dst_addr: IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1)),
            src_port: 8080,
            dst_port: 443,
            protocol: 6,
        };

        let key2 = FlowKey {
            src_addr: IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2)),
            dst_addr: IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1)),
            src_port: 8080,
            dst_port: 443,
            protocol: 6,
        };

        assert_ne!(key1, key2);
    }
}
