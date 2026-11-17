use anyhow::Result;
use ip_packet::IpPacket;
use opentelemetry::{KeyValue, metrics::Counter};
use std::collections::VecDeque;
use std::mem;
use std::task::ready;
use std::task::{Context, Poll, Waker};
use tun::{PacketBatch, Tun};

pub struct Device {
    tun: Option<Box<dyn Tun>>,
    waker: Option<Waker>,

    /// The batch of packets queued since the last call to [`Device::flush_batch`].
    current_batch: PacketBatch,
    /// Completed batches waiting for room in the channel, at most [`tun::CHANNEL_CAPACITY`].
    pending_batches: VecDeque<PacketBatch>,
    dropped_packets: Counter<u64>,
}

impl Device {
    pub(crate) fn new() -> Self {
        Self {
            tun: None,
            waker: None,
            current_batch: PacketBatch::default(),
            pending_batches: VecDeque::new(),
            dropped_packets: otel_instruments::network_packet_dropped(),
        }
    }

    pub(crate) fn set_tun(&mut self, tun: Box<dyn Tun>) {
        tracing::debug!(name = %tun.name(), "Initializing TUN device");

        self.tun = Some(tun);

        if let Some(waker) = self.waker.take() {
            waker.wake();
        }
    }

    pub(crate) fn poll_read(&mut self, cx: &mut Context<'_>) -> Poll<Result<PacketBatch>> {
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
    /// Resolves once all pending batches are in the channel and it has room for another one.
    pub fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        let Some(tun) = self.tun.as_mut() else {
            return Poll::Ready(Ok(()));
        };

        loop {
            let reservation =
                ready!(tun.sender().poll_reserve(cx)).map_err(|_| TunChannelClosed)?;

            let Some(batch) = self.pending_batches.pop_front() else {
                return Poll::Ready(Ok(()));
            };

            reservation.send(batch);
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
            // The batch is full: complete it and start a new one.
            let batch = mem::replace(&mut self.current_batch, PacketBatch::new(packet));

            self.push_pending(batch);
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

        self.push_pending(batch);
    }

    fn push_pending(&mut self, batch: PacketBatch) {
        if self.pending_batches.len() >= tun::CHANNEL_CAPACITY {
            self.dropped_packets.add(
                batch.len() as u64,
                &[
                    KeyValue::new("system.device", "tun"),
                    KeyValue::new("network.io.direction", "transmit"),
                    KeyValue::new("error.type", "QueueFull"),
                ],
            );
            tracing::trace!(
                num_packets = batch.len(),
                "TUN device is full; dropping packets"
            );
            return;
        }

        self.pending_batches.push_back(batch);
    }
}

#[cfg(test)]
impl Device {
    pub(crate) fn num_pending(&self) -> usize {
        self.pending_batches.len()
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

    #[tokio::test]
    async fn flush_fails_when_channel_closed() {
        let mut device = Device::new();
        let (tun, _recv_tx, send_rx) = tun::fake(1);
        drop(send_rx);
        device.set_tun(tun);

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
        let (tun, _recv_tx, mut send_rx) = tun::fake(1);
        device.set_tun(tun);
        let mut cx = Context::from_waker(Waker::noop());

        device.queue(test_packet(1));
        device.flush_batch();
        device.queue(test_packet(2));
        device.flush_batch();
        let full = device.poll_flush(&mut cx);
        device.queue(test_packet(3));
        device.flush_batch();

        assert!(full.is_pending());

        assert_eq!(expect_single(send_rx.recv().await.unwrap()), test_packet(1));
        assert!(device.poll_flush(&mut cx).is_pending());

        assert_eq!(expect_single(send_rx.recv().await.unwrap()), test_packet(2));
        assert!(device.poll_flush(&mut cx).is_pending());

        assert_eq!(expect_single(send_rx.recv().await.unwrap()), test_packet(3));
        assert!(device.poll_flush(&mut cx).is_ready());
    }

    #[tokio::test]
    async fn queue_starts_new_batch_when_full() {
        let mut device = Device::new();
        let (tun, _recv_tx, mut send_rx) = tun::fake(4);
        device.set_tun(tun);

        for i in 0..(2 * tun::MAX_BATCH_SIZE + tun::MAX_BATCH_SIZE / 2) {
            device.queue(test_packet(i as u16));
        }
        device.flush_batch();

        poll_fn(|cx| device.poll_flush(cx)).await.unwrap();

        assert_eq!(send_rx.recv().await.unwrap().len(), tun::MAX_BATCH_SIZE);
        assert_eq!(send_rx.recv().await.unwrap().len(), tun::MAX_BATCH_SIZE);
        assert_eq!(send_rx.recv().await.unwrap().len(), tun::MAX_BATCH_SIZE / 2);
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
}
