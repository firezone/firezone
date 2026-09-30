#![cfg_attr(test, allow(clippy::unwrap_used))]

use bufferpool::{Buffer, BufferPool, VecBuf};
use ip_packet::IpPacket;
use std::sync::LazyLock;

#[cfg(target_vendor = "apple")]
pub mod apple;

#[cfg(target_family = "unix")]
pub mod ioctl;
#[cfg(target_os = "linux")]
pub mod linux;

/// How many packets a single TUN batch may at most hold.
///
/// Apple batches amortize utun syscalls. Linux
/// batches feed TUN and UDP segmentation offloads without crossing packet channels.
pub const MAX_BATCH_SIZE: usize = cfg_select! {
    target_os = "ios" => { 32 }
    target_os = "android" => { 25 }
    target_os = "macos" => { 96 }
    _ => { 100 }
};

static BATCH_POOL: LazyLock<BufferPool<VecBuf<IpPacket>>> =
    LazyLock::new(|| BufferPool::new(MAX_BATCH_SIZE, "ip-packet-batch"));

/// A batch of packets processed in one state transition.
///
/// A batch holds at most [`MAX_BATCH_SIZE`] packets in a pooled buffer:
/// [`PacketBatch::try_push`] hands the packet back once the batch is full, so the
/// storage never grows and moving a batch only copies a pointer. Callers send off
/// a full batch and start a new one with [`PacketBatch::new`]. Emptied batches are
/// cleared on return to the pool by [`VecBuf`]'s `reset`, so stale packets don't
/// keep their pooled payload buffers alive.
#[derive(Debug)]
pub struct PacketBatch {
    inner: Buffer<VecBuf<IpPacket>>,
}

impl Default for PacketBatch {
    fn default() -> Self {
        Self {
            inner: BATCH_POOL.pull(),
        }
    }
}

impl PacketBatch {
    /// Starts a new batch containing the given packet.
    pub fn new(first: IpPacket) -> Self {
        let mut batch = Self::default();
        batch.inner.push(first);

        batch
    }

    /// Appends a packet to the batch, handing it back if the batch is full.
    pub fn try_push(&mut self, packet: IpPacket) -> Result<(), IpPacket> {
        if self.inner.len() == MAX_BATCH_SIZE {
            return Err(packet);
        }

        self.inner.push(packet);

        Ok(())
    }

    /// Removes all packets from the batch, in order.
    pub fn drain(&mut self) -> impl Iterator<Item = IpPacket> + '_ {
        self.inner.drain(..)
    }
}

impl std::ops::Deref for PacketBatch {
    type Target = [IpPacket];

    fn deref(&self) -> &[IpPacket] {
        self.inner.as_slice()
    }
}

pub trait Tun: Send + Sync + 'static {
    fn into_io(self: Box<Self>) -> TunIo;
    fn name(&self) -> &str;
}

/// Owns the platform device and the state needed for its lifetime.
pub enum TunIo {
    #[cfg(target_vendor = "apple")]
    Apple(std::os::fd::OwnedFd),
    #[cfg(target_os = "android")]
    Android(std::os::fd::OwnedFd),
    #[cfg(target_os = "linux")]
    Linux(linux::TunFd<std::os::fd::OwnedFd>),
    #[cfg(windows)]
    Windows {
        session: std::sync::Arc<wintun::Session>,
        owner: std::sync::Arc<dyn Send + Sync>,
    },
    Inspect {
        inner: Box<TunIo>,
        inspect: fn(&IpPacket),
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn batches_return_to_the_pool_empty() {
        let packet = ip_packet::make::udp_packet(
            std::net::Ipv4Addr::LOCALHOST,
            std::net::Ipv4Addr::LOCALHOST,
            1234,
            5678,
            &[],
        )
        .unwrap();

        drop(PacketBatch::new(packet));

        // The dropped batch's storage is recycled; it must come back empty.
        let batch = PacketBatch::default();
        assert!(batch.is_empty());
    }
}
