use std::collections::{BTreeMap, VecDeque};
use std::io;

use bufferpool::{Buffer, BufferPool};
use bytes::BytesMut;
use ip_packet::IpPacket;

const MAX_INBOUND_PACKET_BATCH: usize = 32;
const MAX_SEGMENT_SIZE: usize = ip_packet::MAX_IP_SIZE;

/// Maximum size for a GSO header (IPv4 60 bytes + TCP 60 bytes = 120 bytes)
const MAX_GSO_HEADER_SIZE: usize = 120;

/// Stack-allocated buffer for serialized GSO headers
#[derive(Debug, Clone)]
pub struct GsoHeaderBuf {
    bytes: [u8; MAX_GSO_HEADER_SIZE],
    len: usize,
}

impl Default for GsoHeaderBuf {
    fn default() -> Self {
        Self {
            bytes: [0u8; MAX_GSO_HEADER_SIZE],
            len: 0,
        }
    }
}

impl GsoHeaderBuf {
    /// Create a new empty header buffer
    pub fn new() -> Self {
        Self::default()
    }

    /// Get the serialized header bytes
    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes[..self.len]
    }
}

impl io::Write for GsoHeaderBuf {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let available = MAX_GSO_HEADER_SIZE - self.len;
        if buf.len() > available {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "GSO header buffer full",
            ));
        }
        self.bytes[self.len..self.len + buf.len()].copy_from_slice(buf);
        self.len += buf.len();
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Represents a batch of IP packets to be sent to a TUN device using GSO.
/// This is only used on Linux for batched packet transmission.
#[derive(Debug)]
pub struct IpPacketBatch {
    /// Serialized GSO header (stored on stack)
    header: GsoHeaderBuf,
    /// Buffer containing concatenated payload bodies (without headers)
    payloads: Buffer<BytesMut>,
    /// Size of each payload segment
    segment_size: usize,
}

impl IpPacketBatch {
    /// Create a new IP packet batch
    pub fn new(header: GsoHeaderBuf, payloads: Buffer<BytesMut>, segment_size: usize) -> Self {
        Self {
            header,
            payloads,
            segment_size,
        }
    }

    /// Returns the number of segments in this batch
    #[cfg(test)]
    pub fn segment_count(&self) -> usize {
        self.payloads.len() / self.segment_size
    }

    /// Get the serialized header bytes
    pub fn header_bytes(&self) -> &[u8] {
        self.header.as_bytes()
    }

    /// Get the payload bytes
    pub fn payload_bytes(&self) -> &[u8] {
        &self.payloads
    }

    /// Get the segment size
    pub fn segment_size(&self) -> usize {
        self.segment_size
    }
}

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
    fn serialize(&self) -> io::Result<GsoHeaderBuf> {
        let mut buf = GsoHeaderBuf::new();
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
/// Packets are batched by flow for GSO.
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
                let header = batch
                    .header
                    .serialize()
                    .expect("Failed to serialize header");
                let result = IpPacketBatch::new(header, batch.payloads, batch.segment_size);

                // If no more batches for this flow, remove the entry
                if batches.is_empty() {
                    entry.remove();
                }

                return Some(result);
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

    // TODO: This test is wrong. The last packet in a batch is allowed to be less than the segment size.
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

        let batches = queue.packets().collect::<Vec<_>>();
        assert_eq!(batches.len(), 2);
        assert_eq!(batches[0].segment_count(), 1);
        assert_eq!(batches[0].segment_size(), 4);
        assert_eq!(batches[1].segment_count(), 1);
        assert_eq!(batches[1].segment_size(), 2);
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
        assert_eq!(batches[0].payload_bytes(), &[1, 2, 3, 4, 5, 6, 7, 8]);
    }
}
