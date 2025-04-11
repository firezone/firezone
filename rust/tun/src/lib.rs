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
    fn poll_send_many(
        &mut self,
        cx: &mut Context,
        buf: &mut Vec<IpPacket>,
    ) -> Poll<io::Result<usize>>;

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
