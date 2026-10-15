#![cfg_attr(test, allow(clippy::unwrap_used))]

mod workers;
pub use workers::Workers;

use std::pin::pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering, fence};

use bufferpool::{Buffer, VecBuf};
use ip_packet::IpPacket;
use tokio::sync::mpsc::error::TrySendError;
use tokio::sync::{Notify, mpsc};

/// How many packets a single item on the TUN channels may at most hold.
///
/// The channels exchange whole batches of packets, so the cost of a channel
/// send / receive (and the associated task wake-up) is paid once per batch
/// rather than once per packet.
///
/// On Apple, sized as a multiple of `quinn_udp::BATCH_SIZE` (32): a TUN batch destined
/// for a single peer becomes one GSO transmit, and the Apple UDP send path moves 32
/// datagrams per `sendmsg_x`, so any other size leaves the last syscall of every full
/// batch underfilled. iOS is memory-constrained and gets exactly one syscall's worth;
/// macOS gets three. Both are far below the kernel's `sendmsg_x` / `recvmsg_x` clamp
/// (`kern.ipc.somaxsendmsgx` / `somaxrecvmsgx`, 256 by default).
///
/// Elsewhere the batch size has no syscall quantum to align to - Linux and Android
/// send real GSO super-datagrams of up to 64 segments per syscall regardless of batch
/// size, and Windows sends a whole transmit in one USO call - so those values only
/// balance channel amortisation against buffer memory.
pub const MAX_BATCH_SIZE: usize = cfg_select! {
    target_os = "ios" => { 32 }
    target_os = "android" => { 25 }
    target_os = "macos" => { 96 }
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

bufferpool::buffer_pool!(static PACKET_BATCHES: VecBuf<IpPacket> = (MAX_BATCH_SIZE, "ip-packet-batch"), batch: 4);

/// Worst-case memory usage of the two TUN channels: every slot filled with a full batch of packets,
/// each of which owns a pooled buffer of [`ip_packet::MAX_FZ_PAYLOAD`] bytes.
const MAX_CHANNEL_MEMORY: usize = 2
    * CHANNEL_CAPACITY
    * (size_of::<PacketBatch>()
        + MAX_BATCH_SIZE * (size_of::<IpPacket>() + ip_packet::MAX_FZ_PAYLOAD));

#[cfg(any(target_os = "ios", target_os = "android"))]
const _: () = assert!(MAX_CHANNEL_MEMORY <= 4 * 1024 * 1024);
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const _: () = assert!(MAX_CHANNEL_MEMORY <= 32 * 1024 * 1024);

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
            inner: PACKET_BATCHES.pull(),
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
    let backpressure = Arc::new(Backpressure::default());

    (
        InboundTx {
            tx,
            backpressure: backpressure.clone(),
        },
        InboundRx { rx, backpressure },
    )
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

/// Wakes a reader blocked on a full inbound channel only once the main thread has drained
/// it to [`LOW_WATER_MARK`], instead of on every batch it takes out.
#[derive(Default)]
struct Backpressure {
    blocked: AtomicBool,
    unblocked: Notify,
}

const LOW_WATER_MARK: usize = CHANNEL_CAPACITY / 2;

/// The sending half of the channel of packet batches read from the TUN device.
#[derive(Clone)]
pub struct InboundTx {
    tx: mpsc::Sender<PacketBatch>,
    backpressure: Arc<Backpressure>,
}

impl InboundTx {
    pub async fn send(
        &self,
        mut batch: PacketBatch,
    ) -> Result<(), mpsc::error::SendError<PacketBatch>> {
        loop {
            batch = match self.try_send(batch) {
                Ok(()) => return Ok(()),
                Err(TrySendError::Closed(batch)) => return Err(mpsc::error::SendError(batch)),
                Err(TrySendError::Full(batch)) => batch,
            };

            // Registered before announcing that we are blocked, so the receiver's wake cannot slip
            // in between the announcement and the wait.
            let unblocked = pin!(self.backpressure.unblocked.notified());
            self.backpressure.blocked.store(true, Ordering::Relaxed);
            fence(Ordering::SeqCst);

            batch = match self.try_send(batch) {
                Ok(()) => return Ok(()),
                Err(TrySendError::Closed(batch)) => return Err(mpsc::error::SendError(batch)),
                Err(TrySendError::Full(batch)) => batch,
            };

            unblocked.await;
        }
    }

    pub fn blocking_send(
        &self,
        batch: PacketBatch,
    ) -> Result<(), mpsc::error::SendError<PacketBatch>> {
        futures::executor::block_on(self.send(batch))
    }

    fn try_send(&self, batch: PacketBatch) -> Result<(), TrySendError<PacketBatch>> {
        self.tx.try_send(batch)
    }

    pub fn downgrade(&self) -> mpsc::WeakSender<PacketBatch> {
        self.tx.downgrade()
    }

    /// Completes when the receiving half of the channel is gone.
    pub async fn closed(&self) {
        self.tx.closed().await
    }
}

/// The receiving half of the channel of packet batches read from the TUN device.
pub struct InboundRx {
    rx: mpsc::Receiver<PacketBatch>,
    backpressure: Arc<Backpressure>,
}

impl InboundRx {
    pub fn poll_recv(
        &mut self,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<PacketBatch>> {
        let batch = std::task::ready!(self.rx.poll_recv(cx));
        self.release_backpressure();

        std::task::Poll::Ready(batch)
    }

    pub async fn recv(&mut self) -> Option<PacketBatch> {
        std::future::poll_fn(|cx| self.poll_recv(cx)).await
    }

    pub fn try_recv(&mut self) -> Result<PacketBatch, mpsc::error::TryRecvError> {
        let batch = self.rx.try_recv()?;
        self.release_backpressure();

        Ok(batch)
    }

    fn release_backpressure(&self) {
        fence(Ordering::SeqCst);

        if self.backpressure.blocked.load(Ordering::Relaxed) && self.rx.len() <= LOW_WATER_MARK {
            self.unblock();
        }
    }

    fn unblock(&self) {
        self.backpressure.blocked.store(false, Ordering::Relaxed);
        self.backpressure.unblocked.notify_waiters();
    }
}

impl Drop for InboundRx {
    fn drop(&mut self) {
        // Closes the channel before the wake, so woken senders see it closed.
        self.rx.close();
        self.unblock();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::future::Future as _;

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

    #[test]
    fn blocked_sender_resumes_only_at_low_water_mark() {
        let (tx, mut rx) = inbound_channel();
        for _ in 0..CHANNEL_CAPACITY {
            tx.try_send(PacketBatch::default()).unwrap();
        }
        let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
        let mut send = pin!(tx.send(PacketBatch::default()));
        assert!(send.as_mut().poll(&mut cx).is_pending());

        for _ in 0..CHANNEL_CAPACITY - LOW_WATER_MARK - 1 {
            rx.try_recv().unwrap();
            assert!(send.as_mut().poll(&mut cx).is_pending());
        }
        rx.try_recv().unwrap();

        assert!(send.as_mut().poll(&mut cx).is_ready());
    }
}
