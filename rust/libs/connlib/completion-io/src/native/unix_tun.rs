use super::{
    PacketDevice,
    buffer::{TunBuffer, TunPacket},
};
use anyhow::Result;
use compio::{
    BufResult,
    io::{AsyncRead, AsyncWrite},
    runtime::fd::AsyncFd,
};
use ip_packet::IpPacket;
use std::os::fd::OwnedFd;
use tun::PacketBatch;

/// Owns a plain IP TUN descriptor (`IFF_NO_PI`, without `IFF_VNET_HDR`).
pub struct RawTun(AsyncFd<OwnedFd>);

impl RawTun {
    pub fn from_fd(fd: OwnedFd) -> Result<Self> {
        let device = AsyncFd::new(fd)?;
        Ok(Self(device))
    }
}

impl PacketDevice for RawTun {
    async fn read(&self) -> Result<PacketBatch> {
        let BufResult(result, buffer) = (&self.0).read(TunBuffer::new()).await;
        let len = result?;
        anyhow::ensure!(len > 0, "TUN descriptor closed");
        let packet = IpPacket::new(buffer.inner, len)?;
        Ok(PacketBatch::new(packet))
    }
    async fn write(&self, mut batch: PacketBatch) -> Result<()> {
        for packet in batch.drain() {
            let len = packet.packet().len();
            let BufResult(result, _) = (&self.0).write(TunPacket(packet)).await;
            anyhow::ensure!(result? == len, "Short TUN write");
        }
        Ok(())
    }
}
