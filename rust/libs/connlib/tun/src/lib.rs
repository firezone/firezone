use std::{
    io,
    task::{Context, Poll},
};

use bufferpool::Buffer;
use bytes::BytesMut;
use ip_packet::IpPacket;

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

    /// Get the length of the header
    pub fn len(&self) -> usize {
        self.len
    }

    /// Returns whether the header is empty
    pub fn is_empty(&self) -> bool {
        self.len == 0
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

#[cfg(target_family = "unix")]
pub mod ioctl;
#[cfg(target_family = "unix")]
pub mod unix;

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
    pub fn segment_count(&self) -> usize {
        self.payloads.len() / self.segment_size
    }

    /// Returns the header length
    pub fn header_len(&self) -> usize {
        self.header.len()
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

    /// Returns the total size (header + all payloads)
    pub fn total_len(&self) -> usize {
        self.header_len() + self.payloads.len()
    }
}

pub trait Tun: Send + Sync + 'static {
    /// Check if more packets can be sent.
    fn poll_send_ready(&mut self, cx: &mut Context) -> Poll<io::Result<()>>;

    /// Send a single packet.
    fn send(&mut self, packet: IpPacket) -> io::Result<()>;

    /// Send a batch of packets.
    #[cfg(target_os = "linux")]
    fn send_batch(&mut self, batch: IpPacketBatch) -> io::Result<()>;

    /// Receive a batch of packets up to `max`.
    fn poll_recv_many(
        &mut self,
        cx: &mut Context,
        buf: &mut Vec<IpPacket>,
        max: usize,
    ) -> Poll<usize>;

    /// The name of the TUN device.
    fn name(&self) -> &str;
}
