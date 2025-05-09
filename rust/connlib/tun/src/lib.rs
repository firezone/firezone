use std::{
    io,
    task::{Context, Poll},
};

use ip_packet::IpPacket;

#[cfg(target_family = "unix")]
pub mod ioctl;
#[cfg(target_family = "unix")]
pub mod unix;

pub trait Tun: Send + Sync + 'static {
    /// Check if more packets can be sent.
    fn poll_send_ready(&mut self, cx: &mut Context) -> Poll<io::Result<()>>;
    /// Send a packet.
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
