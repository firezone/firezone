use anyhow::Result;
use futures::FutureExt;
use futures::future::BoxFuture;
use ip_packet::IpPacket;
use smallvec::SmallVec;
use std::mem;
use std::task::ready;
use std::task::{Context, Poll, Waker};
use tun::Tun;

/// How many packets we at most expect to buffer on the stack.
///
/// Assuming the channel to our TUN send thread is completely full, we should at most get one more batch of packets from the UDP thread.
/// How many packets we get there in one batch is platform-dependent but even on platforms like Linux where GSO is well supported,
/// it shouldn't be more than 64 (32 for each IP version).
///
/// Using 128 here is already conservative and in case we exceed it, `SmallVec` will just allocate and not panic.
/// Thus, in the happy path, this will be very efficient and only use stack-space.
const MAX_BUFFERED_PACKETS: usize = 128;

pub struct Device {
    tun: Option<Box<dyn Tun>>,
    waker: Option<Waker>,

    outbound_buffer: SmallVec<[IpPacket; MAX_BUFFERED_PACKETS]>,
    flush_future: Option<BoxFuture<'static, Result<()>>>,
}

impl Device {
    pub(crate) fn new() -> Self {
        Self {
            tun: None,
            waker: None,
            outbound_buffer: SmallVec::new(),
            flush_future: None,
        }
    }

    pub(crate) fn set_tun(&mut self, tun: Box<dyn Tun>) {
        tracing::debug!(name = %tun.name(), "Initializing TUN device");

        self.tun = Some(tun);

        if let Some(waker) = self.waker.take() {
            waker.wake();
        }
    }

    pub(crate) fn poll_read_many(
        &mut self,
        cx: &mut Context<'_>,
        buf: &mut Vec<IpPacket>,
        max: usize,
    ) -> Poll<Result<usize>> {
        let Some(tun) = self.tun.as_mut() else {
            self.waker = Some(cx.waker().clone());
            return Poll::Pending;
        };

        let n = ready!(tun.receiver().poll_recv_many(cx, buf, max));

        if n == 0 {
            return Poll::Ready(Err(anyhow::Error::new(TunChannelClosed)));
        }

        Poll::Ready(Ok(n))
    }

    pub fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        let Some(tun) = self.tun.as_ref() else {
            return Poll::Ready(Ok(()));
        };

        let Some(fut) = self.flush_future.as_mut() else {
            if self.outbound_buffer.is_empty() {
                return Poll::Ready(Ok(()));
            }

            tracing::trace!("Got buffered packets, building flush future");

            let buffered_packets = mem::take(&mut self.outbound_buffer);
            let tx = tun.sender().clone();

            self.flush_future = Some(
                async move {
                    for packet in buffered_packets {
                        tx.send(packet).await.map_err(|_| TunChannelClosed)?;
                    }

                    Ok(())
                }
                .boxed(),
            );

            return self.poll_flush(cx);
        };

        let res = ready!(fut.poll_unpin(cx));

        tracing::trace!("Flush complete");

        // Reset after we are done.
        self.flush_future = None;

        Poll::Ready(res)
    }

    pub fn send(&mut self, packet: IpPacket) {
        debug_assert!(
            !packet.is_fz_p2p_control(),
            "FZ p2p control protocol packets should never leave `connlib`"
        );

        let Some(tun) = self.tun.as_ref() else {
            return;
        };

        // Preserve ordering: if a flush is already in flight, this packet must queue behind the
        // packets being flushed. Otherwise a `try_send` here could slip it into the channel ahead
        // of them, reordering the stream we write to the TUN device.
        if self.flush_future.is_some() {
            self.outbound_buffer.push(packet);
            return;
        }

        // Likewise, if we haven't started flushing yet but are already buffering (a previous
        // `try_send` hit a full channel), this packet must queue behind those buffered packets.
        if !self.outbound_buffer.is_empty() {
            self.outbound_buffer.push(packet);
            return;
        }

        // Fast path: nothing queued, send immediately if the channel has capacity.
        if let Err(packet) = tun.sender().try_send(packet).map_err(|e| e.into_inner()) {
            tracing::trace!(?packet, "Unable to send packet into channel, buffering");
            self.outbound_buffer.push(packet);
        }
    }
}

#[derive(Debug, thiserror::Error)]
#[error("Channel to TUN device thread is closed")]
pub struct TunChannelClosed;

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::ErrorExt;
    use std::net::Ipv4Addr;

    #[tokio::test]
    async fn flush_returns_error_when_sender_channel_closed() {
        let mut device = Device::new();
        let (test_tun, send_rx, _recv_tx) = TestTun::new();
        drop(send_rx);
        device.set_tun(Box::new(test_tun));

        let packet =
            ip_packet::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 1234, 5678, &[])
                .unwrap();

        device.send(packet);

        let err = std::future::poll_fn(|cx| device.poll_flush(cx))
            .await
            .unwrap_err();
        assert!(err.any_is::<TunChannelClosed>());

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
        device.set_tun(Box::new(test_tun));

        let packet =
            ip_packet::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 1234, 5678, &[1])
                .unwrap();

        // We cycle 3 times to ensure we can send and flush again repeatedly.
        for _ in 0..3 {
            device.send(packet.clone());
            device.send(packet.clone()); // This one should get buffered.

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
    async fn packets_do_not_overtake_buffered_packets_while_flushing() {
        let _guard = logging::test("trace");

        let mut device = Device::new();
        let (test_tun, mut send_rx, _send_tx) = TestTun::new();
        device.set_tun(Box::new(test_tun));

        let packet_a = test_packet(1);
        let packet_b = test_packet(2);
        let packet_c = test_packet(3);

        // A claims the single channel slot via the `try_send` fast-path.
        device.send(packet_a.clone());
        // B finds the channel full and gets buffered.
        device.send(packet_b.clone());

        // Start flushing B. It can't make progress while the channel is still full, so the flush
        // stays in-flight (`flush_future` is `Some`).
        let poll = device.poll_flush_noop_waker();
        assert!(
            poll.is_pending(),
            "Flush should suspend while channel is full"
        );

        // C arrives while the flush is in-flight. It must queue behind B rather than racing ahead
        // through `try_send`.
        device.send(packet_c.clone());

        // Drain the channel and finish flushing. The receiver must observe A, then B, then C, and
        // never A, C, B.
        assert_eq!(send_rx.recv().await.unwrap(), packet_a);

        std::future::poll_fn(|cx| device.poll_flush(cx))
            .await
            .unwrap();
        assert_eq!(send_rx.recv().await.unwrap(), packet_b);

        std::future::poll_fn(|cx| device.poll_flush(cx))
            .await
            .unwrap();
        assert_eq!(send_rx.recv().await.unwrap(), packet_c);
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
            let (send_tx, send_rx) = tun::outbound_channel_for_test(1);
            let (recv_tx, recv_rx) = tun::inbound_channel_for_test(1);

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

    impl Device {
        fn poll_flush_noop_waker(&mut self) -> Poll<Result<()>> {
            self.poll_flush(&mut Context::from_waker(futures::task::noop_waker_ref()))
        }
    }
}
