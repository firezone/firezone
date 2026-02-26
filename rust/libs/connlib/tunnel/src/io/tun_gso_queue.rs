use std::collections::{BTreeMap, VecDeque};

use bufferpool::{Buffer, BufferPool};
use bytes::BytesMut;
use ip_packet::IpPacket;
use tun::IpPacketBatch;

use super::MAX_INBOUND_PACKET_BATCH;

const MAX_SEGMENT_SIZE: usize = ip_packet::MAX_IP_SIZE;

/// GSO header for batching (parsed form)
#[derive(Debug, Clone)]
enum GsoHeader {
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
    /// Serialize the header into a GsoHeaderBuf
    fn serialize(&self) -> std::io::Result<tun::GsoHeaderBuf> {
        let mut buf = tun::GsoHeaderBuf::new();
        match self {
            Self::Ipv4Tcp { ipv4, tcp } => {
                ipv4.write_raw(&mut buf)
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
                tcp.write(&mut buf)
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
            }
            Self::Ipv6Tcp { ipv6, tcp } => {
                ipv6.write(&mut buf)
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
                tcp.write(&mut buf)
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
            }
            Self::Ipv4Udp { ipv4, udp } => {
                ipv4.write_raw(&mut buf)
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
                udp.write(&mut buf)
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
            }
            Self::Ipv6Udp { ipv6, udp } => {
                ipv6.write(&mut buf)
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
                udp.write(&mut buf)
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
            }
        }
        Ok(buf)
    }
}

/// Canonical header that groups packets for GSO batching.
/// This represents the IP + L4 header with variable fields normalized.
/// For TCP: sequence numbers, checksums are zeroed
/// For UDP: length, checksums are zeroed
#[derive(Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Clone)]
struct CanonicalHeaderKey {
    /// Serialized header bytes with variable fields zeroed out
    bytes: Vec<u8>,
}

impl CanonicalHeaderKey {
    /// Extract canonical header from an IP packet
    /// Returns None if the packet cannot be batched (not TCP/UDP, or parse failure)
    fn from_packet(packet: &IpPacket) -> Option<(CanonicalHeaderKey, GsoHeader)> {
        // Pattern match on (IP version, L4 protocol) to handle all cases
        let header = match (
            packet.ipv4_header(),
            packet.ipv6_header(),
            packet.as_tcp(),
            packet.as_udp(),
        ) {
            // IPv4 + TCP
            (Some(ipv4), None, Some(tcp), None) => GsoHeader::Ipv4Tcp {
                ipv4: ip_packet::Ipv4Header {
                    total_len: 0,       // Variable: will change per segment
                    header_checksum: 0, // Variable: will be recalculated
                    ..ipv4
                },
                tcp: ip_packet::TcpHeader {
                    sequence_number: 0, // Variable: will change per segment
                    checksum: 0,        // Variable: will be calculated with GSO
                    ..tcp.to_header()
                },
            },
            // IPv6 + TCP
            (None, Some(ipv6), Some(tcp), None) => GsoHeader::Ipv6Tcp {
                ipv6: ip_packet::Ipv6Header {
                    payload_length: 0, // Variable: will change per segment
                    ..ipv6
                },
                tcp: ip_packet::TcpHeader {
                    sequence_number: 0, // Variable: will change per segment
                    checksum: 0,        // Variable: will be calculated with GSO
                    ..tcp.to_header()
                },
            },
            // IPv4 + UDP
            (Some(ipv4), None, None, Some(udp)) => GsoHeader::Ipv4Udp {
                ipv4: ip_packet::Ipv4Header {
                    total_len: 0,       // Variable: will change per segment
                    header_checksum: 0, // Variable: will be recalculated
                    ..ipv4
                },
                udp: ip_packet::UdpHeader {
                    length: 0,   // Variable: will change per segment
                    checksum: 0, // Variable: will be calculated with GSO
                    ..udp.to_header()
                },
            },
            // IPv6 + UDP
            (None, Some(ipv6), None, Some(udp)) => GsoHeader::Ipv6Udp {
                ipv6: ip_packet::Ipv6Header {
                    payload_length: 0, // Variable: will change per segment
                    ..ipv6
                },
                udp: ip_packet::UdpHeader {
                    length: 0,   // Variable: will change per segment
                    checksum: 0, // Variable: will be calculated with GSO
                    ..udp.to_header()
                },
            },
            // Everything else (ICMP, malformed packets, etc.) cannot be batched
            _ => return None,
        };

        // Serialize to bytes for use as map key
        let mut bytes = Vec::new();
        header
            .serialize()
            .ok()?
            .as_bytes()
            .iter()
            .for_each(|&b| bytes.push(b));
        let key = CanonicalHeaderKey { bytes };

        Some((key, header))
    }
}

/// A batch of payloads that can be sent with GSO
struct PayloadBatch {
    /// The canonical header (stored to avoid re-parsing)
    header: GsoHeader,
    /// The size of each payload segment
    segment_size: usize,
    /// Concatenated payload bodies (without headers)
    payloads: Buffer<BytesMut>,
}

/// Holds IP packets that need to be sent, indexed by flow and segment size.
/// On Linux, packets are batched by flow for GSO. On other platforms, this
/// queue exists but is not used.
pub struct TunGsoQueue {
    /// Map from canonical header key to batches of payloads
    inner: BTreeMap<CanonicalHeaderKey, VecDeque<PayloadBatch>>,
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
        let (key, header) = CanonicalHeaderKey::from_packet(packet).ok_or(NotBatchable)?;

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
        let batches = self.inner.entry(key).or_default();

        // Check if we can append to existing batch
        let Some(batch) = batches.back_mut() else {
            // No existing batch, create new one
            let mut buffer = self.buffer_pool.pull();
            buffer.clear();
            buffer.extend_from_slice(payload);
            batches.push_back(PayloadBatch {
                header,
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
            header,
            segment_size: payload_len,
            payloads: buffer,
        });

        Ok(())
    }

    pub fn packets(&mut self) -> impl Iterator<Item = IpPacketBatch> + '_ {
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
    type Item = IpPacketBatch;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            let mut entry = self.queue.inner.first_entry()?;

            let Some(batch) = entry.get_mut().pop_front() else {
                entry.remove();
                continue;
            };

            // Serialize header and return GSO batch
            let gso_header = match batch.header.serialize() {
                Ok(buf) => buf,
                Err(e) => {
                    tracing::warn!("Failed to serialize GSO header: {e}");
                    continue;
                }
            };

            return Some(IpPacketBatch::new(
                gso_header,
                batch.payloads,
                batch.segment_size,
            ));
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

        assert_eq!(out.segment_count(), 1);
        assert_eq!(out.payload_bytes(), &[1, 2, 3, 4]);
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
        assert_eq!(out.segment_count(), 2);

        // Verify payloads concatenated correctly
        let payloads = out.payload_bytes();
        assert_eq!(&payloads[0..4], &[1, 2, 3, 4]);
        assert_eq!(&payloads[4..8], &[5, 6, 7, 8]);

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
        assert_eq!(out1.segment_count(), 1);

        let out2 = iter.next().unwrap();
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
        assert_eq!(out1.segment_count(), 1);

        let out2 = iter.next().unwrap();
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

        assert_eq!(out.segment_count(), 3);
        assert_eq!(out.payload_bytes(), &[1, 2, 3, 4, 5, 6]);
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

        assert_eq!(out.segment_count(), 2);
        assert_eq!(out.payload_bytes(), &[1, 2, 3, 4, 5, 6, 7, 8]);
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
