use anyhow::Result;
use ip_packet::IpPacket;
use std::collections::VecDeque;
use std::mem;
use std::task::ready;
use std::task::{Context, Poll, Waker};
use tun::{OutboundTx, PacketFlow, Tun};

pub struct Device {
    // `tx` holds a clone of the TUN device's sender and must be dropped before `tun`:
    // `Tun`'s drop can wait for its worker threads, which only exit once all sender
    // clones are gone. Fields drop in declaration order.
    tx: Option<OutboundTx>,
    tun: Option<Box<dyn Tun>>,
    waker: Option<Waker>,

    /// The batch of packets queued since the last call to [`Device::flush_batch`].
    current_batch: PacketFlow,
    /// Completed batches waiting for room in the channel.
    pending_batches: VecDeque<PacketFlow>,
}

impl Device {
    pub(crate) fn new() -> Self {
        Self {
            tx: None,
            tun: None,
            waker: None,
            current_batch: PacketFlow::default(),
            pending_batches: VecDeque::new(),
        }
    }

    pub(crate) fn set_tun(&mut self, tun: Box<dyn Tun>) {
        tracing::debug!(name = %tun.name(), "Initializing TUN device");

        self.tx = Some(tun.sender().clone());
        self.tun = Some(tun);

        if let Some(waker) = self.waker.take() {
            waker.wake();
        }
    }

    pub(crate) fn poll_read(&mut self, cx: &mut Context<'_>) -> Poll<Result<PacketFlow>> {
        let Some(tun) = self.tun.as_mut() else {
            self.waker = Some(cx.waker().clone());
            return Poll::Pending;
        };

        let Some(batch) = ready!(tun.receiver().poll_recv(cx)) else {
            return Poll::Ready(Err(anyhow::Error::new(TunChannelClosed)));
        };

        Poll::Ready(Ok(batch))
    }

    /// Sends all pending batches into the channel.
    ///
    /// Resolves once nothing is left to send, at which point the channel has room for another batch.
    pub fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        let Some(tx) = self.tx.as_mut() else {
            return Poll::Ready(Ok(()));
        };

        loop {
            ready!(tx.poll_reserve(cx)).map_err(|_| TunChannelClosed)?;

            let Some(batch) = self.pending_batches.pop_front() else {
                return Poll::Ready(Ok(()));
            };

            tx.send_item(batch).map_err(|_| TunChannelClosed)?;
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
            // The batch is full or the flow changed: complete it and start a new one.
            let batch = mem::replace(&mut self.current_batch, PacketFlow::new(packet));

            self.pending_batches.push_back(batch);
        }
    }

    /// Marks the end of the current batch of packets.
    ///
    /// The batch becomes a single channel item, sent by [`Device::poll_flush`].
    pub fn flush_batch(&mut self) {
        if self.current_batch.is_empty() {
            return;
        }

        let batch = mem::take(&mut self.current_batch);

        self.pending_batches.push_back(batch);
    }
}

#[derive(Debug, thiserror::Error)]
#[error("Channel to TUN device thread is closed")]
pub struct TunChannelClosed;

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::ErrorExt;
    use std::future::poll_fn;
    use std::net::Ipv4Addr;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::task::Wake;

    #[tokio::test]
    async fn flush_fails_when_channel_closed() {
        let mut device = Device::new();
        let (test_tun, send_rx, _recv_tx) = TestTun::with_capacity(1);
        drop(send_rx);
        device.set_tun(Box::new(test_tun));

        device.queue(test_packet(1));
        device.flush_batch();

        let first = poll_fn(|cx| device.poll_flush(cx)).await.unwrap_err();
        let second = poll_fn(|cx| device.poll_flush(cx)).await.unwrap_err();

        assert!(first.any_is::<TunChannelClosed>());
        assert!(second.any_is::<TunChannelClosed>());
    }

    #[tokio::test]
    async fn full_channel_is_not_ready_until_drained() {
        let mut device = Device::new();
        let (test_tun, mut send_rx, _recv_tx) = TestTun::with_capacity(1);
        device.set_tun(Box::new(test_tun));
        let woken = Arc::new(FlagWaker::default());
        let waker = Waker::from(woken.clone());
        let mut cx = Context::from_waker(&waker);

        device.queue(test_packet(1));
        device.flush_batch();
        device.queue(test_packet(2));
        device.flush_batch();
        let full = device.poll_flush(&mut cx);
        device.queue(test_packet(3));
        device.flush_batch();

        assert!(full.is_pending());
        assert!(!woken.take());

        assert_eq!(expect_single(send_rx.recv().await.unwrap()), test_packet(1));
        assert!(woken.take());
        assert!(device.poll_flush(&mut cx).is_pending());

        assert_eq!(expect_single(send_rx.recv().await.unwrap()), test_packet(2));
        assert!(woken.take());
        assert!(device.poll_flush(&mut cx).is_pending());

        assert_eq!(expect_single(send_rx.recv().await.unwrap()), test_packet(3));
        assert!(woken.take());
        assert!(device.poll_flush(&mut cx).is_ready());
    }

    #[tokio::test]
    async fn queue_starts_new_batch_when_full() {
        let mut device = Device::new();
        let (test_tun, mut send_rx, _send_tx) = TestTun::with_capacity(4);
        device.set_tun(Box::new(test_tun));

        for _ in 0..(2 * tun::MAX_BATCH_SIZE + tun::MAX_BATCH_SIZE / 2) {
            device.queue(test_packet(1));
        }
        device.flush_batch();

        poll_fn(|cx| device.poll_flush(cx)).await.unwrap();

        assert_eq!(send_rx.recv().await.unwrap().len(), tun::MAX_BATCH_SIZE);
        assert_eq!(send_rx.recv().await.unwrap().len(), tun::MAX_BATCH_SIZE);
        assert_eq!(send_rx.recv().await.unwrap().len(), tun::MAX_BATCH_SIZE / 2);
    }

    fn expect_single(mut batch: PacketFlow) -> IpPacket {
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

    #[derive(Default)]
    struct FlagWaker(AtomicBool);

    impl FlagWaker {
        fn take(&self) -> bool {
            self.0.swap(false, Ordering::SeqCst)
        }
    }

    impl Wake for FlagWaker {
        fn wake(self: Arc<Self>) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    struct TestTun {
        send_tx: tun::OutboundTx,
        recv_rx: tun::InboundRx,
    }

    impl TestTun {
        fn with_capacity(capacity: usize) -> (Self, tun::OutboundRx, tun::InboundTx) {
            let (send_tx, send_rx) = tun::outbound_channel_for_test(capacity);
            let (recv_tx, recv_rx) = tun::inbound_channel();

            (Self { send_tx, recv_rx }, send_rx, recv_tx)
        }
    }

    impl Tun for TestTun {
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
}
