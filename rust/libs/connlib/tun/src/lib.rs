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
/// On Linux, this can represent a batch of packets (segment_size > 0).
/// On other platforms, only single packets are used (segment_size = 0).
pub struct IpPacketOut {
    /// Buffer containing one or more IP packet payloads
    pub packet: Buffer<BytesMut>,
    /// Size of each segment in the buffer. 0 means single packet (no GSO).
    pub segment_size: usize,
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
