#![cfg_attr(test, allow(clippy::unwrap_used))]

mod workers;
pub use workers::Workers;

use ip_packet::IpPacket;
use std::task::{Context, Poll};
use tokio::sync::mpsc;
use tokio_util::sync::PollSender;

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
/// A batch holds at most [`MAX_BATCH_SIZE`] packets: [`PacketBatch::try_push`] hands
/// the packet back once the batch is full, so the storage never grows and moving a
/// batch only copies a pointer. Callers send off a full batch and start a new one
/// with [`PacketBatch::new`].
#[derive(Debug)]
pub struct PacketBatch {
    inner: Vec<IpPacket>,
}

impl Default for PacketBatch {
    fn default() -> Self {
        Self {
            inner: Vec::with_capacity(MAX_BATCH_SIZE),
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
    pub fn drain(&mut self) -> impl ExactSizeIterator<Item = IpPacket> + '_ {
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
    fn sender(&mut self) -> &mut OutboundTx;

    /// Get a mutable reference to the receiver for inbound packets.
    fn receiver(&mut self) -> &mut InboundRx;

    /// The name of the TUN device.
    fn name(&self) -> &str;
}

/// Creates the channel connecting the main thread to the thread writing to the TUN device.
pub fn outbound_channel() -> (OutboundTx, OutboundRx) {
    let (tx, rx) = mpsc::channel(CHANNEL_CAPACITY);

    (OutboundTx(PollSender::new(tx)), OutboundRx(rx))
}

/// Creates the channel connecting the thread reading from the TUN device to the main thread.
pub fn inbound_channel() -> (InboundTx, InboundRx) {
    let (tx, rx) = mpsc::channel(CHANNEL_CAPACITY);

    (InboundTx(tx), InboundRx(rx))
}

/// Creates a TUN device that is not backed by a real one; its outbound channel holds `capacity` batches.
///
/// Returns the ends of its channels that the TUN threads would hold.
#[doc(hidden)]
pub fn fake(capacity: usize) -> (Box<dyn Tun>, InboundTx, OutboundRx) {
    let (outbound_tx, outbound_rx) = mpsc::channel(capacity);
    let (inbound_tx, inbound_rx) = inbound_channel();

    let device = FakeDevice {
        outbound_tx: OutboundTx(PollSender::new(outbound_tx)),
        inbound_rx,
    };

    (Box::new(device), inbound_tx, OutboundRx(outbound_rx))
}

struct FakeDevice {
    outbound_tx: OutboundTx,
    inbound_rx: InboundRx,
}

impl Tun for FakeDevice {
    fn sender(&mut self) -> &mut OutboundTx {
        &mut self.outbound_tx
    }

    fn receiver(&mut self) -> &mut InboundRx {
        &mut self.inbound_rx
    }

    fn name(&self) -> &str {
        "test"
    }
}

/// The sending half of the channel to the thread writing to the TUN device.
///
/// Each item is one batch of packets; the end of a batch marks the boundary
/// up to which the TUN thread may coalesce packets before writing them out.
pub struct OutboundTx(PollSender<PacketBatch>);

impl OutboundTx {
    pub fn try_send(
        &self,
        batch: PacketBatch,
    ) -> Result<(), mpsc::error::TrySendError<PacketBatch>> {
        match self.0.get_ref() {
            Some(tx) => tx.try_send(batch),
            None => Err(mpsc::error::TrySendError::Closed(batch)),
        }
    }

    /// Reserves a slot in the channel for one batch.
    ///
    /// Dropping the [`Reservation`] keeps the slot for the next one.
    pub fn poll_reserve(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Result<Reservation<'_>, mpsc::error::SendError<()>>> {
        match self.0.poll_reserve(cx) {
            Poll::Ready(Ok(())) => Poll::Ready(Ok(Reservation(&mut self.0))),
            Poll::Ready(Err(_)) => Poll::Ready(Err(mpsc::error::SendError(()))),
            Poll::Pending => Poll::Pending,
        }
    }
}

/// A slot reserved in the channel to the thread writing to the TUN device.
pub struct Reservation<'a>(&'a mut PollSender<PacketBatch>);

impl Reservation<'_> {
    pub fn send(self, batch: PacketBatch) {
        self.0
            .send_item(batch)
            .expect("a reservation always holds a slot");
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

    /// Completes when the receiving half of the channel is gone.
    pub async fn closed(&self) {
        self.0.closed().await
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
