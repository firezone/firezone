use ip_packet::IpPacket;
use tokio::sync::mpsc;

#[cfg(target_family = "unix")]
pub mod ioctl;
#[cfg(target_family = "unix")]
pub mod unix;

#[cfg(any(target_os = "macos", target_os = "ios"))]
pub mod apple;

/// Capacity of the channels connecting the TUN device threads to the main thread.
const CHANNEL_CAPACITY: usize = cfg_select! {
    target_os = "linux" => { 10_000 }
    target_os = "windows" => { 10_000 }
    target_os = "macos" => { 10_000 }
    target_os = "ios" => { 1_000 }
    target_os = "android" => { 1_000 }
    _ => { 1_000 }
};

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

/// Creates an outbound channel with an explicit capacity; only meant for tests.
pub fn outbound_channel_for_test(capacity: usize) -> (OutboundTx, OutboundRx) {
    let (tx, rx) = mpsc::channel(capacity);

    (OutboundTx(tx), OutboundRx(rx))
}

/// The sending half of the channel to the thread writing to the TUN device.
#[derive(Clone)]
pub struct OutboundTx(mpsc::Sender<IpPacket>);

impl OutboundTx {
    #[expect(
        clippy::result_large_err,
        reason = "The error carries the unsent packet by design"
    )]
    pub fn try_send(&self, packet: IpPacket) -> Result<(), mpsc::error::TrySendError<IpPacket>> {
        self.0.try_send(packet)
    }

    pub async fn send(&self, packet: IpPacket) -> Result<(), mpsc::error::SendError<IpPacket>> {
        self.0.send(packet).await
    }

    pub fn downgrade(&self) -> mpsc::WeakSender<IpPacket> {
        self.0.downgrade()
    }
}

/// The receiving half of the channel to the thread writing to the TUN device.
pub struct OutboundRx(mpsc::Receiver<IpPacket>);

impl OutboundRx {
    pub async fn recv(&mut self) -> Option<IpPacket> {
        self.0.recv().await
    }

    pub async fn recv_many(&mut self, buffer: &mut Vec<IpPacket>, limit: usize) -> usize {
        self.0.recv_many(buffer, limit).await
    }

    pub fn blocking_recv(&mut self) -> Option<IpPacket> {
        self.0.blocking_recv()
    }
}

/// The sending half of the channel of [`IpPacket`]s read from the TUN device.
#[derive(Clone)]
pub struct InboundTx(mpsc::Sender<IpPacket>);

impl InboundTx {
    pub async fn reserve_many(
        &self,
        n: usize,
    ) -> Result<mpsc::PermitIterator<'_, IpPacket>, mpsc::error::SendError<()>> {
        self.0.reserve_many(n).await
    }

    pub async fn send(&self, packet: IpPacket) -> Result<(), mpsc::error::SendError<IpPacket>> {
        self.0.send(packet).await
    }

    #[expect(
        clippy::result_large_err,
        reason = "The error carries the unsent packet by design"
    )]
    pub fn blocking_send(&self, packet: IpPacket) -> Result<(), mpsc::error::SendError<IpPacket>> {
        self.0.blocking_send(packet)
    }

    pub fn downgrade(&self) -> mpsc::WeakSender<IpPacket> {
        self.0.downgrade()
    }
}

/// The receiving half of the channel of [`IpPacket`]s read from the TUN device.
pub struct InboundRx(mpsc::Receiver<IpPacket>);

impl InboundRx {
    pub fn poll_recv_many(
        &mut self,
        cx: &mut std::task::Context<'_>,
        buffer: &mut Vec<IpPacket>,
        limit: usize,
    ) -> std::task::Poll<usize> {
        self.0.poll_recv_many(cx, buffer, limit)
    }

    pub fn poll_recv(
        &mut self,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<IpPacket>> {
        self.0.poll_recv(cx)
    }

    pub async fn recv(&mut self) -> Option<IpPacket> {
        self.0.recv().await
    }

    pub fn try_recv(&mut self) -> Result<IpPacket, mpsc::error::TryRecvError> {
        self.0.try_recv()
    }
}
