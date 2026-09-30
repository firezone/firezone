use anyhow::Result;
use futures::FutureExt;
use futures::future::LocalBoxFuture;
use ip_packet::IpPacket;
use std::collections::VecDeque;
use std::mem;
use std::task::ready;
use std::task::{Context, Poll, Waker};
use tun::{PacketBatch, Tun, TunIo};

pub struct Device {
    // A pending write owns the old device until its future is dropped.
    flush_future: Option<LocalBoxFuture<'static, Result<()>>>,
    tun: Option<Box<dyn TunIo>>,
    waker: Option<Waker>,
    error: Option<anyhow::Error>,

    /// The batch of packets queued since the last call to [`Device::flush_batch`].
    current_batch: PacketBatch,
    /// Completed batches waiting to be written.
    pending_batches: VecDeque<PacketBatch>,
}

impl Device {
    pub(crate) fn new() -> Self {
        Self {
            tun: None,
            waker: None,
            error: None,
            current_batch: PacketBatch::default(),
            pending_batches: VecDeque::new(),
            flush_future: None,
        }
    }

    pub(crate) fn set_tun(&mut self, tun: Box<dyn Tun>) {
        tracing::debug!(name = %tun.name(), "Initializing TUN device");

        self.flush_future = None;
        self.pending_batches.clear();
        self.current_batch = PacketBatch::default();
        match tun.into_io() {
            Ok(io) => {
                self.tun = Some(io);
                self.error = None;
            }
            Err(error) => {
                self.tun = None;
                self.error = Some(error);
            }
        }

        if let Some(waker) = self.waker.take() {
            waker.wake();
        }
    }

    pub(crate) fn poll_read(&mut self, cx: &mut Context<'_>) -> Poll<Result<PacketBatch>> {
        if let Some(error) = self.error.take() {
            return Poll::Ready(Err(TunIoError(error).into()));
        }
        let Some(tun) = self.tun.as_mut() else {
            self.waker = Some(cx.waker().clone());
            return Poll::Pending;
        };
        tun.poll_read(cx).map_err(|error| TunIoError(error).into())
    }

    pub fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        loop {
            if let Some(future) = &mut self.flush_future {
                let result = ready!(future.poll_unpin(cx));
                self.flush_future = None;
                result.map_err(TunIoError)?;
            }
            let Some(tun) = &self.tun else {
                return Poll::Ready(Ok(()));
            };
            let Some(batch) = self.pending_batches.pop_front() else {
                return Poll::Ready(Ok(()));
            };
            self.flush_future = Some(tun.send(batch));
        }
    }

    /// Queues a packet for the TUN device.
    ///
    /// Queued packets are buffered until the current batch is completed with
    /// [`Device::flush_batch`].
    pub fn queue(&mut self, packet: IpPacket) {
        debug_assert!(
            !packet.is_fz_p2p_control(),
            "FZ p2p control protocol packets should never leave `connlib`"
        );

        if self.tun.is_none() {
            return;
        }

        if let Err(packet) = self.current_batch.try_push(packet) {
            // The batch is full: hand it off and start a new one.
            let batch = mem::replace(&mut self.current_batch, PacketBatch::new(packet));

            self.enqueue_batch(batch);
        }
    }

    /// Completes the current batch for coalescing and writing to the TUN device.
    pub fn flush_batch(&mut self) {
        if self.current_batch.is_empty() {
            return;
        }

        let batch = mem::take(&mut self.current_batch);

        self.enqueue_batch(batch);
    }

    fn enqueue_batch(&mut self, batch: PacketBatch) {
        self.pending_batches.push_back(batch);
    }

    #[cfg(test)]
    pub(crate) fn set_io(&mut self, io: Box<dyn TunIo>) {
        self.flush_future = None;
        self.tun = Some(io);
    }
}

#[derive(Debug, thiserror::Error)]
#[error("TUN I/O failed: {0:#}")]
pub struct TunIoError(#[source] anyhow::Error);

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::ErrorExt as _;
    use std::net::Ipv4Addr;

    #[tokio::test]
    async fn flush_returns_error_when_sender_channel_closed() {
        let mut device = Device::new();
        let (test_tun, send_rx, _recv_tx) = TestTun::new();
        drop(send_rx);
        device.set_io(Box::new(test_tun));

        let packet =
            ip_packet::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 1234, 5678, &[])
                .unwrap();

        device.queue(packet);
        device.flush_batch();

        let err = std::future::poll_fn(|cx| device.poll_flush(cx))
            .await
            .unwrap_err();
        assert!(err.any_is::<TunIoError>());

        // Ensure polling twice doesn't panic.
        std::future::poll_fn(|cx| device.poll_flush(cx))
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn flush_future_is_reset_after_completion() {
        let _guard = logging::test("trace");

        let mut device = Device::new();
        let (test_tun, mut send_rx, _send_tx) = TestTun::new();
        device.set_io(Box::new(test_tun));

        let packet =
            ip_packet::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 1234, 5678, &[1])
                .unwrap();

        // We cycle 3 times to ensure we can send and flush again repeatedly.
        for _ in 0..3 {
            device.queue(packet.clone());
            device.flush_batch();
            device.queue(packet.clone());
            device.flush_batch(); // This batch should get buffered.

            let poll = device.poll_flush_noop_waker();
            assert!(poll.is_pending(), "Flush should suspend if channel is full");

            send_rx.recv().await.unwrap();

            std::future::poll_fn(|cx| device.poll_flush(cx))
                .await
                .unwrap();

            send_rx.recv().await.unwrap();
        }
    }

    #[tokio::test]
    async fn batches_do_not_overtake_pending_batches_while_flushing() {
        let _guard = logging::test("trace");

        let mut device = Device::new();
        let (test_tun, mut send_rx, _send_tx) = TestTun::new();
        device.set_io(Box::new(test_tun));

        let packet_a = test_packet(1);
        let packet_b = test_packet(2);
        let packet_c = test_packet(3);

        // Flush A into the fake device's single channel slot.
        device.queue(packet_a.clone());
        device.flush_batch();
        assert!(device.poll_flush_noop_waker().is_ready());
        // B finds the channel full and gets buffered.
        device.queue(packet_b.clone());
        device.flush_batch();

        // Start flushing B. It can't make progress while the channel is still full, so the flush
        // stays in-flight (`flush_future` is `Some`).
        let poll = device.poll_flush_noop_waker();
        assert!(
            poll.is_pending(),
            "Flush should suspend while channel is full"
        );

        // C arrives while the flush is in-flight. It must queue behind B rather than racing ahead
        // through `try_send`.
        device.queue(packet_c.clone());
        device.flush_batch();

        // Drain the channel and finish flushing. The receiver must observe A, then B, then C, and
        // never A, C, B.
        assert_eq!(expect_single(send_rx.recv().await.unwrap()), packet_a);

        let (flushed, (batch_b, batch_c)) =
            tokio::join!(std::future::poll_fn(|cx| device.poll_flush(cx)), async {
                (send_rx.recv().await.unwrap(), send_rx.recv().await.unwrap())
            });
        flushed.unwrap();
        assert_eq!(expect_single(batch_b), packet_b);
        assert_eq!(expect_single(batch_c), packet_c);
    }

    #[tokio::test]
    async fn queue_starts_new_batch_when_full() {
        let mut device = Device::new();
        let (test_tun, mut send_rx, _send_tx) = TestTun::with_capacity(3);
        device.set_io(Box::new(test_tun));

        for i in 0..(2 * tun::MAX_BATCH_SIZE + 50) {
            device.queue(test_packet(i as u16));
        }
        device.flush_batch();

        std::future::poll_fn(|cx| device.poll_flush(cx))
            .await
            .unwrap();

        assert_eq!(send_rx.recv().await.unwrap().len(), tun::MAX_BATCH_SIZE);
        assert_eq!(send_rx.recv().await.unwrap().len(), tun::MAX_BATCH_SIZE);
        assert_eq!(send_rx.recv().await.unwrap().len(), 50);
    }

    fn expect_single(mut batch: PacketBatch) -> IpPacket {
        assert_eq!(batch.len(), 1, "Expected exactly one packet in the batch");

        batch.drain().next().unwrap()
    }

    fn test_packet(dst_port: u16) -> IpPacket {
        ip_packet::make::udp_packet(
            Ipv4Addr::LOCALHOST,
            Ipv4Addr::LOCALHOST,
            1234,
            dst_port,
            &[],
        )
        .unwrap()
    }

    struct TestTun {
        send_tx: tun::OutboundTx,
        recv_rx: tun::InboundRx,
    }

    impl TestTun {
        fn new() -> (Self, tun::OutboundRx, tun::InboundTx) {
            Self::with_capacity(1)
        }

        fn with_capacity(capacity: usize) -> (Self, tun::OutboundRx, tun::InboundTx) {
            let (send_tx, send_rx) = tun::outbound_channel_for_test(capacity);
            let (recv_tx, recv_rx) = tun::inbound_channel();

            (Self { send_tx, recv_rx }, send_rx, recv_tx)
        }
    }

    impl tun::ChannelTun for TestTun {
        fn sender(&self) -> &tun::OutboundTx {
            &self.send_tx
        }

        fn receiver(&mut self) -> &mut tun::InboundRx {
            &mut self.recv_rx
        }

        fn name(&self) -> &str {
            "test"
        }
    }

    impl Device {
        fn poll_flush_noop_waker(&mut self) -> Poll<Result<()>> {
            self.poll_flush(&mut Context::from_waker(futures::task::noop_waker_ref()))
        }
    }
}
