use std::collections::{BTreeMap, VecDeque};

use arrayvec::ArrayVec;
use bufferpool::{Buffer, BufferPool};
use bytes::BytesMut;
use ip_packet::IpPacket;

const MAX_INBOUND_PACKET_BATCH: usize = 32;
const MAX_SEGMENT_SIZE: usize = ip_packet::MAX_IP_SIZE;

/// A batch of IP packets ready to be sent with GSO
#[derive(Debug)]
pub struct IpPacketBatch {
    /// Canonical header (parsed, with variable fields zeroed)
    pub header: GsoHeader,
    /// Concatenated payload bodies (without headers)
    pub payloads: Buffer<BytesMut>,
    /// Size of each payload segment
    pub segment_size: usize,
}

impl IpPacketBatch {
    pub fn num_packets(&self) -> usize {
        self.payloads.len() / self.segment_size
    }
}

/// Parsed header info needed for GSO batching (with variable fields zeroed)
/// Stores serialized header bytes ready for writev
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum GsoHeader {
    Ipv4Tcp {
        ipv4: ArrayVec<u8, 60>,
        tcp: ArrayVec<u8, 60>,
    },
    Ipv6Tcp {
        ipv6: [u8; 40],
        tcp: ArrayVec<u8, 60>,
    },
    Ipv4Udp {
        ipv4: ArrayVec<u8, 60>,
        udp: [u8; 8],
    },
    Ipv6Udp {
        ipv6: [u8; 40],
        udp: [u8; 8],
    },
}

impl GsoHeader {
    /// Parse from packet and zero out variable fields, then serialize to bytes
    fn from_packet(packet: &IpPacket) -> Option<Self> {
        match (
            packet.ipv4_header(),
            packet.ipv6_header(),
            packet.as_tcp(),
            packet.as_udp(),
        ) {
            (Some(ipv4), None, Some(tcp), None) => {
                let ipv4 = ip_packet::Ipv4Header {
                    total_len: 0,
                    header_checksum: 0,
                    ..ipv4
                };
                let tcp = ip_packet::TcpHeader {
                    sequence_number: 0,
                    checksum: 0,
                    ..tcp.to_header()
                };

                Some(Self::Ipv4Tcp {
                    ipv4: ipv4.to_bytes(),
                    tcp: tcp.to_bytes(),
                })
            }
            (None, Some(ipv6), Some(tcp), None) => {
                let ipv6 = ip_packet::Ipv6Header {
                    payload_length: 0,
                    ..ipv6
                };
                let tcp = ip_packet::TcpHeader {
                    sequence_number: 0,
                    checksum: 0,
                    ..tcp.to_header()
                };

                Some(Self::Ipv6Tcp {
                    ipv6: ipv6.to_bytes(),
                    tcp: tcp.to_bytes(),
                })
            }
            (Some(ipv4), None, None, Some(udp)) => {
                let ipv4 = ip_packet::Ipv4Header {
                    total_len: 0,
                    header_checksum: 0,
                    ..ipv4
                };
                let udp = ip_packet::UdpHeader {
                    length: 0,
                    checksum: 0,
                    ..udp.to_header()
                };

                Some(Self::Ipv4Udp {
                    ipv4: ipv4.to_bytes(),
                    udp: udp.to_bytes(),
                })
            }
            (None, Some(ipv6), None, Some(udp)) => {
                let ipv6 = ip_packet::Ipv6Header {
                    payload_length: 0,
                    ..ipv6
                };
                let udp = ip_packet::UdpHeader {
                    length: 0,
                    checksum: 0,
                    ..udp.to_header()
                };

                Some(Self::Ipv6Udp {
                    ipv6: ipv6.to_bytes(),
                    udp: udp.to_bytes(),
                })
            }
            _ => None,
        }
    }

    /// Get header length
    pub fn header_len(&self) -> u16 {
        let (l3, l4) = self.header_slices();

        (l3.len() + l4.len()) as u16
    }

    pub fn header_slices(&self) -> (&[u8], &[u8]) {
        match self {
            GsoHeader::Ipv4Tcp { ipv4, tcp } => (ipv4.as_slice(), tcp.as_slice()),
            GsoHeader::Ipv6Tcp { ipv6, tcp } => (ipv6.as_slice(), tcp.as_slice()),
            GsoHeader::Ipv4Udp { ipv4, udp } => (ipv4.as_slice(), udp.as_slice()),
            GsoHeader::Ipv6Udp { ipv6, udp } => (ipv6.as_slice(), udp.as_slice()),
        }
    }

    /// Get checksum start offset
    pub fn csum_start(&self) -> u16 {
        match self {
            Self::Ipv4Tcp { ipv4, .. } | Self::Ipv4Udp { ipv4, .. } => ipv4.len() as u16,
            Self::Ipv6Tcp { ipv6, .. } | Self::Ipv6Udp { ipv6, .. } => ipv6.len() as u16,
        }
    }

    /// Get checksum offset within L4 header
    pub fn csum_offset(&self) -> u16 {
        match self {
            Self::Ipv4Tcp { .. } | Self::Ipv6Tcp { .. } => 16, // TCP checksum
            Self::Ipv4Udp { .. } | Self::Ipv6Udp { .. } => 6,  // UDP checksum
        }
    }
}

pub struct TunGsoQueue {
    inner: BTreeMap<GsoHeader, VecDeque<(usize, Buffer<BytesMut>)>>,
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

    pub fn enqueue(&mut self, packet: &IpPacket) -> Result<(), NotBatchable> {
        // Parse header (already has variable fields zeroed)
        let header = GsoHeader::from_packet(packet).ok_or(NotBatchable)?;

        let maybe_tcp = packet.as_tcp().map(|t| t.payload());
        let maybe_udp = packet.as_udp().map(|u| u.payload());

        let payload = maybe_tcp.or(maybe_udp).ok_or(NotBatchable)?;

        let payload_len = payload.len();

        // Get or create batch list for this flow (use header as key)
        let batches = self.inner.entry(header).or_default();

        let Some((batch_size, buffer)) = batches.back_mut() else {
            batches.push_back((payload_len, self.buffer_pool.pull_initialised(payload)));
            return Ok(());
        };

        let batch_size = *batch_size;

        // A batch is considered "ongoing" if so far we have only pushed packets of the same length.
        let batch_is_ongoing = buffer.len() % batch_size == 0;

        if batch_is_ongoing && payload_len <= batch_size {
            buffer.extend_from_slice(payload);
            return Ok(());
        }

        batches.push_back((payload_len, self.buffer_pool.pull_initialised(payload)));

        Ok(())
    }

    /// Drain all batches from the queue
    pub fn packets(&mut self) -> impl Iterator<Item = IpPacketBatch> + '_ {
        DrainPacketsIter { queue: self }
    }
}

struct DrainPacketsIter<'a> {
    queue: &'a mut TunGsoQueue,
}

impl Iterator for DrainPacketsIter<'_> {
    type Item = IpPacketBatch;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            let mut entry = self.queue.inner.first_entry()?;
            let Some((batch_size, buffer)) = entry.get_mut().pop_front() else {
                entry.remove();
                continue;
            };

            return Some(IpPacketBatch {
                header: entry.key().clone(),
                payloads: buffer,
                segment_size: batch_size,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ip_packet::make;
    use std::net::Ipv4Addr;

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
        assert_eq!(batches[0].segment_size, 4);
        assert_eq!(batches[0].payloads.as_ref(), &[1, 2, 3, 4]);
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
        assert_eq!(batches[0].segment_size, 4);
        assert_eq!(batches[0].payloads.as_ref(), &[1, 2, 3, 4, 5, 6]);
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
        assert_eq!(batches[0].payloads.as_ref(), &[1, 2, 3, 4, 5, 6, 7, 8]);
    }
}
