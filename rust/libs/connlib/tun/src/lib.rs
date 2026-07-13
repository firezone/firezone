#![cfg_attr(test, allow(clippy::unwrap_used))]

use bufferpool::{Buffer, BufferPool, VecBuf};
use ip_packet::IpPacket;
use std::sync::LazyLock;
use tokio::sync::mpsc;

#[cfg(target_family = "unix")]
pub mod ioctl;
#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_family = "unix")]
pub mod unix;

#[cfg(any(target_os = "macos", target_os = "ios"))]
pub mod apple;

/// How many packets a single item on the TUN channels may at most hold.
///
/// The channels exchange whole batches of packets, so the cost of a channel
/// send / receive (and the associated task wake-up) is paid once per batch
/// rather than once per packet.
///
/// Mobile platforms are memory-constrained and cannot afford to buffer big
/// batches of packets, so we use a smaller limit there. The desktop value also
/// stays below the kernel's `kern.ipc.somaxrecvmsgx` clamp on Apple platforms.
pub const MAX_BATCH_SIZE: usize = cfg_select! {
    target_os = "ios" => { 25 }
    target_os = "android" => { 25 }
    _ => { 100 }
};

/// Capacity (in batches) of the channels connecting the TUN device threads to the main thread.
const CHANNEL_CAPACITY: usize = cfg_select! {
    target_os = "linux" => { 100 }
    target_os = "windows" => { 100 }
    target_os = "macos" => { 100 }
    target_os = "ios" => { 40 }
    target_os = "android" => { 40 }
    _ => { 40 }
};

static BATCH_POOL: LazyLock<BufferPool<VecBuf<IpPacket>>> =
    LazyLock::new(|| BufferPool::new(MAX_BATCH_SIZE, "ip-packet-batch"));

/// A batch of packets, exchanged over the TUN channels as a single item.
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
    /// Get a reference to the sender for outbound packets.
    fn sender(&self) -> &OutboundTx;

    /// Get a mutable reference to the receiver for inbound packets.
    fn receiver(&mut self) -> &mut InboundRx;

    /// The name of the TUN device.
    fn name(&self) -> &str;
}

/// Creates the channel connecting the main thread to the thread writing to the TUN device.
pub fn outbound_channel() -> (OutboundTx, OutboundRx) {
    let (tx, rx) = mpsc::channel(CHANNEL_CAPACITY);

    (OutboundTx(tx), OutboundRx(rx))
}

/// Creates the channel connecting the thread reading from the TUN device to the main thread.
pub fn inbound_channel() -> (InboundTx, InboundRx) {
    let (tx, rx) = mpsc::channel(CHANNEL_CAPACITY);

    (InboundTx(tx), InboundRx(rx))
}

/// Creates an outbound channel with an explicit capacity.
///
/// Only meant for tests that need to exercise behaviour on a full channel.
pub fn outbound_channel_for_test(capacity: usize) -> (OutboundTx, OutboundRx) {
    let (tx, rx) = mpsc::channel(capacity);

    (OutboundTx(tx), OutboundRx(rx))
}

/// The sending half of the channel to the thread writing to the TUN device.
///
/// Each item is one batch of packets; the end of a batch marks the boundary
/// up to which the TUN thread may coalesce packets before writing them out.
#[derive(Clone)]
pub struct OutboundTx(mpsc::Sender<PacketBatch>);

impl OutboundTx {
    pub fn try_send(
        &self,
        batch: PacketBatch,
    ) -> Result<(), mpsc::error::TrySendError<PacketBatch>> {
        self.0.try_send(batch)
    }

    pub async fn send(
        &self,
        batch: PacketBatch,
    ) -> Result<(), mpsc::error::SendError<PacketBatch>> {
        self.0.send(batch).await
    }

    pub fn downgrade(&self) -> mpsc::WeakSender<PacketBatch> {
        self.0.downgrade()
    }
}

/// The receiving half of the channel to the thread writing to the TUN device.
pub struct OutboundRx(mpsc::Receiver<PacketBatch>);

impl OutboundRx {
    pub async fn recv(&mut self) -> Option<PacketBatch> {
        self.0.recv().await
    }

    pub fn blocking_recv(&mut self) -> Option<PacketBatch> {
        self.0.blocking_recv()
    }
}

/// The sending half of the channel of packet batches read from the TUN device.
#[derive(Clone)]
pub struct InboundTx(mpsc::Sender<PacketBatch>);

impl InboundTx {
    pub async fn send(
        &self,
        batch: PacketBatch,
    ) -> Result<(), mpsc::error::SendError<PacketBatch>> {
        self.0.send(batch).await
    }

    pub fn blocking_send(
        &self,
        batch: PacketBatch,
    ) -> Result<(), mpsc::error::SendError<PacketBatch>> {
        self.0.blocking_send(batch)
    }

    pub fn downgrade(&self) -> mpsc::WeakSender<PacketBatch> {
        self.0.downgrade()
    }
}

/// The receiving half of the channel of packet batches read from the TUN device.
pub struct InboundRx(mpsc::Receiver<PacketBatch>);

impl InboundRx {
    pub fn poll_recv(
        &mut self,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<PacketBatch>> {
        self.0.poll_recv(cx)
    }

    pub async fn recv(&mut self) -> Option<PacketBatch> {
        self.0.recv().await
    }

    pub fn try_recv(&mut self) -> Result<PacketBatch, mpsc::error::TryRecvError> {
        self.0.try_recv()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Worst-case memory usage of the two TUN channels: every slot filled with a
    /// full batch of packets, each of which owns a pooled buffer of
    /// [`ip_packet::MAX_FZ_PAYLOAD`] bytes.
    const MAX_CHANNEL_MEMORY: usize = 2
        * CHANNEL_CAPACITY
        * (size_of::<PacketBatch>()
            + MAX_BATCH_SIZE * (size_of::<IpPacket>() + ip_packet::MAX_FZ_PAYLOAD));

    /// iOS network extensions are limited to 50 MB of memory; the channels must only
    /// ever use a small fraction of that.
    #[cfg(any(target_os = "ios", target_os = "android"))]
    #[test]
    fn channel_memory_fits_mobile_budget() {
        const { assert!(MAX_CHANNEL_MEMORY <= 4 * 1024 * 1024) }
    }

    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    #[test]
    fn channel_memory_fits_desktop_budget() {
        const { assert!(MAX_CHANNEL_MEMORY <= 32 * 1024 * 1024) }
    }

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
