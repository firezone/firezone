use std::{
    collections::{BTreeMap, VecDeque},
    
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
    src_addr: [u8; 16], // Source IP (IPv4 mapped to IPv6 format)
    dst_addr: [u8; 16], // Destination IP (IPv4 mapped to IPv6 format)
    src_port: u16,      // Source port (0 for non-TCP/UDP)
    dst_port: u16,      // Destination port (0 for non-TCP/UDP)
    protocol: u8,       // IP protocol number (6=TCP, 17=UDP)
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
        // Parse packet to extract flow key
        let key = match extract_flow_key(&packet) {
            Some(k) => k,
            None => {
                tracing::debug!("Failed to extract flow key, skipping packet");
                return;
            }
        };

        let payload_len = packet.packet().len();
        let packet_bytes = packet.packet();

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
fn extract_flow_key(packet: &IpPacket) -> Option<FlowKey> {
    // For now, return None to disable batching until Phase 5
    // TODO: Implement full flow key extraction
    let _ = packet;
    None
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
