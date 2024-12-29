use bytes::BytesMut;
use firezone_logging::err_with_src;
use futures::{ready, SinkExt, StreamExt};
use gat_lending_iterator::LendingIterator;
use socket_factory::{DatagramIn, DatagramSegmentIter, SocketFactory, UdpSocket};
use std::{
    io,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    task::{Context, Poll, Waker},
};

type DatagramOut =
    socket_factory::DatagramOut<lockfree_object_pool::SpinLockOwnedReusable<BytesMut>>;

const UNSPECIFIED_V4_SOCKET: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0);
const UNSPECIFIED_V6_SOCKET: SocketAddrV6 = SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 0, 0, 0);

#[derive(Default)]
pub(crate) struct Sockets {
    waker: Option<Waker>,

    socket_v4: Option<ThreadedUdpSocket>,
    socket_v6: Option<ThreadedUdpSocket>,
}

impl Sockets {
    pub fn rebind(&mut self, socket_factory: &dyn SocketFactory<UdpSocket>) {
        self.socket_v4 =
            ThreadedUdpSocket::new(socket_factory, SocketAddr::V4(UNSPECIFIED_V4_SOCKET))
                .inspect_err(|e| tracing::info!("Failed to bind IPv4 socket: {e}"))
                .ok();
        self.socket_v6 =
            ThreadedUdpSocket::new(socket_factory, SocketAddr::V6(UNSPECIFIED_V6_SOCKET))
                .inspect_err(|e| tracing::info!("Failed to bind IPv6 socket: {e}"))
                .ok();

        if let Some(waker) = self.waker.take() {
            waker.wake();
        }
    }

    pub fn poll_has_sockets(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        if self.socket_v4.is_none() && self.socket_v6.is_none() {
            let previous = self.waker.replace(cx.waker().clone());

            if previous.is_none() {
                // If we didn't have a waker yet, it means we just lost our sockets. Let the user know everything will be suspended.
                tracing::error!("No available UDP sockets")
            }

            return Poll::Pending;
        }

        Poll::Ready(())
    }

    pub fn poll_send_ready(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if let Some(socket) = self.socket_v4.as_mut() {
            ready!(socket.poll_send_ready(cx))?;
        }

        if let Some(socket) = self.socket_v6.as_mut() {
            ready!(socket.poll_send_ready(cx))?;
        }

        Poll::Ready(Ok(()))
    }

    pub fn send(&mut self, datagram: DatagramOut) -> io::Result<()> {
        let socket = match datagram.dst {
            SocketAddr::V4(dst) => self.socket_v4.as_mut().ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotConnected,
                    format!("failed send packet to {dst}: no IPv4 socket"),
                )
            })?,
            SocketAddr::V6(dst) => self.socket_v6.as_mut().ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotConnected,
                    format!("failed send packet to {dst}: no IPv6 socket"),
                )
            })?,
        };
        socket.send(datagram)?;

        Ok(())
    }

    pub fn poll_recv_from(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<impl for<'a> LendingIterator<Item<'a> = DatagramIn<'a>>>> {
        let mut iter = PacketIter::new();

        if let Some(Poll::Ready(packets)) = self.socket_v4.as_mut().map(|s| s.poll_recv_from(cx)) {
            iter.ip4 = Some(packets?);
        }

        if let Some(Poll::Ready(packets)) = self.socket_v6.as_mut().map(|s| s.poll_recv_from(cx)) {
            iter.ip6 = Some(packets?);
        }

        if iter.is_empty() {
            return Poll::Pending;
        }

        Poll::Ready(Ok(iter))
    }
}

struct PacketIter<T4, T6> {
    ip4: Option<T4>,
    ip6: Option<T6>,
}

impl<T4, T6> PacketIter<T4, T6> {
    fn new() -> Self {
        Self {
            ip4: None,
            ip6: None,
        }
    }

    fn is_empty(&self) -> bool {
        self.ip4.is_none() && self.ip6.is_none()
    }
}

impl<T4, T6> LendingIterator for PacketIter<T4, T6>
where
    T4: 'static + for<'a> LendingIterator<Item<'a> = DatagramIn<'a>>,
    T6: 'static + for<'a> LendingIterator<Item<'a> = DatagramIn<'a>>,
{
    type Item<'a> = DatagramIn<'a>;

    fn next(&mut self) -> Option<Self::Item<'_>> {
        if let Some(packet) = self.ip4.as_mut().and_then(|i| i.next()) {
            return Some(packet);
        }

        if let Some(packet) = self.ip6.as_mut().and_then(|i| i.next()) {
            return Some(packet);
        }

        None
    }
}

struct ThreadedUdpSocket {
    outbound_tx: flume::r#async::SendSink<'static, DatagramOut>,
    inbound_rx: flume::r#async::RecvStream<'static, DatagramSegmentIter>,
}

impl ThreadedUdpSocket {
    #[expect(clippy::unwrap_in_result, reason = "We unwrap in the new thread.")]
    fn new(sf: &dyn SocketFactory<UdpSocket>, addr: SocketAddr) -> io::Result<Self> {
        let mut socket = sf(&addr)?;

        let (outbound_tx, outbound_rx) = flume::bounded(100);
        let (inbound_tx, inbound_rx) = flume::bounded(100);

        std::thread::Builder::new()
            .name(
                match addr {
                    SocketAddr::V4(_) => "UDP send/recv IPv4",
                    SocketAddr::V6(_) => "UDP send/recv IPv6",
                }
                .to_owned(),
            )
            .spawn(|| {
                tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("Failed to spawn tokio runtime on UDP thread")
                    .block_on(async move {
                        loop {
                            match futures::future::select(
                                outbound_rx.recv_async(),
                                std::future::poll_fn(|cx| socket.poll_recv_from(cx)),
                            )
                            .await
                            {
                                futures::future::Either::Left((Ok(datagram), _)) => {
                                    if let Err(e) = socket.send(datagram).await {
                                        tracing::debug!(
                                            "Failed to send datagram: {}",
                                            err_with_src(&e)
                                        )
                                    };
                                }
                                futures::future::Either::Left((
                                    Err(flume::RecvError::Disconnected),
                                    _,
                                )) => {
                                    tracing::debug!(
                                        "Channel for outbound datagrams closed; exiting UDP thread"
                                    );
                                    break;
                                }
                                futures::future::Either::Right((Ok(datagrams), _)) => {
                                    if inbound_tx.send_async(datagrams).await.is_err() {
                                        tracing::debug!(
                                        "Channel for inbound datagrams closed; exiting UDP thread"
                                    );
                                        break;
                                    }
                                }
                                futures::future::Either::Right((Err(e), _)) => {
                                    tracing::debug!(
                                        "Failed to receive from socket: {}",
                                        err_with_src(&e)
                                    )
                                }
                            }
                        }
                    })
            })?;

        Ok(Self {
            outbound_tx: outbound_tx.into_sink(),
            inbound_rx: inbound_rx.into_stream(),
        })
    }

    fn poll_send_ready(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.outbound_tx
            .poll_ready_unpin(cx)
            .map_err(io::Error::other)
    }

    fn send(&mut self, datagram: DatagramOut) -> io::Result<()> {
        self.outbound_tx
            .start_send_unpin(datagram)
            .map_err(io::Error::other)
    }

    fn poll_recv_from(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<DatagramSegmentIter>> {
        let Some(iter) = ready!(self.inbound_rx.poll_next_unpin(cx)) else {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "UDP recv thread stopped",
            )));
        };

        Poll::Ready(Ok(iter))
    }
}
