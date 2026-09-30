//! Packet transport used by the shared client and gateway event loops.

use anyhow::Result;
use bufferpool::{Buffer, VecBuf};
use ip_packet::IpPacket;
use socket_factory::{DatagramBatch, DatagramIn, DatagramOut, SocketFactory, UdpSocket};
use std::{
    sync::Arc,
    task::{Context, Poll},
};
use tun::{PacketBatch, Tun};

use crate::{io::Device, sockets::Sockets};

pub mod completion;
#[cfg(any(target_os = "linux", target_os = "windows"))]
pub mod native;
#[cfg(any(target_os = "linux", target_os = "windows"))]
pub type PlatformIo = native::Native;
#[cfg(not(any(target_os = "linux", target_os = "windows")))]
pub type PlatformIo = Threaded;

#[derive(Debug, thiserror::Error)]
#[error("Packet transport stopped: {0:#}")]
pub struct PacketIoFailed(#[source] pub anyhow::Error);

pub trait NetworkInput {
    fn for_each(&mut self, callback: impl FnMut(DatagramIn<'_>));
}

impl NetworkInput for Buffer<VecBuf<DatagramBatch>> {
    fn for_each(&mut self, mut callback: impl FnMut(DatagramIn<'_>)) {
        for datagram in self.iter_mut().flat_map(|batch| batch.drain()) {
            callback(datagram);
        }
    }
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

pub struct Threaded {
    sockets: Sockets,
    device: Device,
}

impl Threaded {
    pub fn new(factory: Arc<dyn SocketFactory<UdpSocket>>) -> Self {
        let mut sockets = Sockets::default();
        sockets.rebind(factory);
        Self {
            sockets,
            device: Device::new(),
        }
    }
}

impl PacketIo for Threaded {
    type Network = Buffer<VecBuf<DatagramBatch>>;
    fn poll_network(&mut self, cx: &mut Context<'_>) -> Poll<Buffer<VecBuf<DatagramBatch>>> {
        self.sockets.poll_recv_from(cx)
    }
    fn poll_tun(&mut self, cx: &mut Context<'_>) -> Poll<Result<PacketBatch>> {
        self.device.poll_read(cx)
    }
    fn poll_error(&mut self, cx: &mut Context<'_>) -> Poll<anyhow::Error> {
        self.sockets.poll_error(cx)
    }
    fn poll_send_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        self.sockets.poll_send_ready(cx)
    }
    fn send(&mut self, datagram: DatagramOut) -> Result<()> {
        self.sockets.send(datagram)?;
        Ok(())
    }
    fn queue_tun(&mut self, packet: IpPacket) {
        self.device.queue(packet);
    }
    fn flush_tun_batch(&mut self) {
        self.device.flush_batch();
    }
    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        self.device.poll_flush(cx)
    }
    fn set_tun(&mut self, tun: Box<dyn Tun>) {
        self.device.set_tun(tun);
    }
    fn reset(&mut self, factory: Arc<dyn SocketFactory<UdpSocket>>) {
        self.sockets.rebind(factory);
    }
}
