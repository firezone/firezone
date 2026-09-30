//! Packet transport used by the shared client and gateway event loops.

use anyhow::Result;
use ip_packet::IpPacket;
use socket_factory::{DatagramIn, DatagramOut, SocketFactory, UdpSocket};
use std::{
    sync::Arc,
    task::{Context, Poll},
};
use tun::{PacketBatch, Tun};

pub(crate) mod completion;
pub mod native;
pub type PlatformIo = native::Native;

pub fn platform(factory: Arc<dyn SocketFactory<UdpSocket>>) -> PlatformIo {
    native::Native::new(factory)
}

#[derive(Debug, thiserror::Error)]
#[error("Packet transport stopped: {0:#}")]
pub struct PacketIoFailed(#[source] pub anyhow::Error);

pub trait NetworkInput {
    fn for_each(&mut self, callback: impl FnMut(DatagramIn<'_>));
}

pub trait PacketIo: 'static {
    type Network: NetworkInput;
    fn poll_network(&mut self, cx: &mut Context<'_>) -> Poll<Self::Network>;
    fn poll_tun(&mut self, cx: &mut Context<'_>) -> Poll<Result<PacketBatch>>;
    fn poll_error(&mut self, cx: &mut Context<'_>) -> Poll<anyhow::Error>;
    fn poll_send_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>>;
    fn send(&mut self, datagram: DatagramOut) -> Result<()>;
    fn queue_tun(&mut self, packet: IpPacket);
    fn flush_tun_batch(&mut self);
    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>>;
    fn poll_shutdown(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        self.poll_flush(cx)
    }
    fn set_tun(&mut self, tun: Box<dyn Tun>);
    fn reset(&mut self, factory: Arc<dyn SocketFactory<UdpSocket>>);
}
