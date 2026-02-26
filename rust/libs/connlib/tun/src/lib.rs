use std::{
    io,
    task::{Context, Poll},
};

use bufferpool::Buffer;
use bytes::BytesMut;
use ip_packet::IpPacket;

#[cfg(target_family = "unix")]
pub mod ioctl;
#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_family = "unix")]
pub mod unix;

/// Represents one or more IP packets to be sent to a TUN device.
/// On Linux, this represents a GSO batch with separate header and payloads.
/// On other platforms, only single packets are used (payloads contains full packet).
pub struct IpPacketOut {
    /// Header bytes (IP + L4 header) - included once
    /// Empty for non-Linux single packets
    pub header: Vec<u8>,
    /// Buffer containing concatenated payload bodies (without headers)
    /// For non-Linux single packets, contains the full packet (header + payload)
    pub payloads: Buffer<BytesMut>,
    /// Size of each payload segment
    pub segment_size: usize,
}

impl IpPacketOut {
    /// Returns true if this represents a GSO batch
    pub fn is_gso(&self) -> bool {
        !self.header.is_empty()
    }

    /// Returns the number of segments in this packet/batch
    pub fn segment_count(&self) -> usize {
        if self.header.is_empty() {
            // Non-Linux single packet
            1
        } else {
            // Linux GSO batch
            self.payloads.len() / self.segment_size
        }
    }

    /// Returns the header length
    pub fn header_len(&self) -> usize {
        self.header.len()
    }

    /// Returns the total size (header + all payloads)
    pub fn total_len(&self) -> usize {
        if self.header.is_empty() {
            // Non-Linux single packet: payloads contains the full packet
            self.payloads.len()
        } else {
            // Linux GSO batch: header once + concatenated payloads
            self.header.len() + self.payloads.len()
        }
    }
}

pub trait Tun: Send + Sync + 'static {
    /// Check if more packets can be sent.
    fn poll_send_ready(&mut self, cx: &mut Context) -> Poll<io::Result<()>>;

    #[cfg(target_os = "linux")]
    /// Send a packet or batch (Linux only).
    fn send(&mut self, packet: IpPacketOut) -> io::Result<()>;

    #[cfg(not(target_os = "linux"))]
    /// Send a single packet (non-Linux platforms).
    fn send(&mut self, packet: IpPacket) -> io::Result<()>;

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
