use crate::otel;
use anyhow::{Context as _, Result};
use futures::{SinkExt, StreamExt, ready};
use gat_lending_iterator::LendingIterator;
use socket_factory::DatagramOut;
use socket_factory::{DatagramIn, DatagramSegmentIter, SocketFactory, UdpSocket};
use std::time::{Duration, Instant};
use std::{
    io,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    sync::Arc,
    task::{Context, Poll, Waker},
};

const DEFAULT_LISTEN_PORT: u16 = EPHEMERAL_PORT_RANGE_START + FIRE;
const EPHEMERAL_PORT_RANGE_START: u16 = 49152;
const FIRE: u16 = 3473; // "FIRE" when typed on a phone pad.

const UNSPECIFIED_V4_SOCKET: SocketAddrV4 =
    SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, DEFAULT_LISTEN_PORT);
const UNSPECIFIED_V6_SOCKET: SocketAddrV6 =
    SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, DEFAULT_LISTEN_PORT, 0, 0);

#[derive(Default)]
pub(crate) struct Sockets {
    waker: Option<Waker>,

    socket_v4: Option<ThreadedUdpSocket>,
    socket_v6: Option<ThreadedUdpSocket>,
}

impl Sockets {
    pub fn rebind(&mut self, socket_factory: Arc<dyn SocketFactory<UdpSocket>>) {
        self.socket_v4 = None;
        self.socket_v6 = None;

        self.socket_v4 = ThreadedUdpSocket::new(
            socket_factory.clone(),
            SocketAddr::V4(UNSPECIFIED_V4_SOCKET),
        )
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

    pub fn poll_send_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        if let Some(socket) = self.socket_v4.as_mut() {
            ready!(socket.poll_send_ready(cx))?;
        }

        if let Some(socket) = self.socket_v6.as_mut() {
            ready!(socket.poll_send_ready(cx))?;
        }

        Poll::Ready(Ok(()))
    }

    pub fn send(&mut self, datagram: DatagramOut) -> Result<()> {
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
    ) -> Poll<Result<impl for<'a> LendingIterator<Item<'a> = DatagramIn<'a>> + use<>>> {
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
    thread_name: String,
    join_handle: std::thread::JoinHandle<()>,
    channels: Option<Channels>,
}

struct Channels {
    outbound_tx: flume::r#async::SendSink<'static, DatagramOut>,
    inbound_rx: flume::r#async::RecvStream<'static, Result<DatagramSegmentIter>>,
}

impl ThreadedUdpSocket {
    fn new(sf: Arc<dyn SocketFactory<UdpSocket>>, preferred_addr: SocketAddr) -> io::Result<Self> {
        let (outbound_tx, outbound_rx) = flume::bounded(10);
        let (inbound_tx, inbound_rx) = flume::bounded(10);
        let (error_tx, error_rx) = flume::bounded(0);

        let thread_name = match preferred_addr {
            SocketAddr::V4(_) => "UDP IPv4".to_owned(),
            SocketAddr::V6(_) => "UDP IPv6".to_owned(),
        };
        let join_handle = std::thread::Builder::new()
            .name(thread_name.clone())
            .spawn(move || {
                let runtime = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(r) => r,
                    Err(e) => {
                        let _ = error_tx.send(Err(e));
                        return;
                    }
                };

                // Enter guard to create UDP socket.
                let _guard = runtime.enter();

                let mut socket = match listen(
                    sf,
                    // Listen on the preferred address, fall back to picking a free port if that doesn't work
                    &[preferred_addr, SocketAddr::new(preferred_addr.ip(), 0)],
                ) {
                    Ok(s) => s,
                    Err(e) => {
                        let _ = error_tx.send(Err(e));
                        return;
                    }
                };

                let io_error_counter = opentelemetry::global::meter("connlib")
                    .u64_counter("system.network.errors")
                    .with_description("Number of IO errors encountered")
                    .with_unit("{error}")
                    .build();

                if let Err(e) = socket.set_buffer_sizes(
                    socket_factory::SEND_BUFFER_SIZE,
                    socket_factory::RECV_BUFFER_SIZE,
                ) {
                    tracing::warn!("Failed to set socket buffer sizes: {e}");
                };

                let socket = Arc::new(socket);

                let send = runtime.spawn({
                    let io_error_counter = io_error_counter.clone();
                    let inbound_tx = inbound_tx.clone();
                    let socket = socket.clone();

                    async move {
                        while let Ok(datagram) = outbound_rx.recv_async().await {
                            tokio::task::yield_now().await;

                            if let Err(e) = socket.send(datagram).await {
                                if let Some(io) = e.downcast_ref::<io::Error>() {
                                    io_error_counter.add(
                                        1,
                                        &[
                                            otel::attr::network_io_direction_transmit(),
                                            otel::attr::network_type_for_addr(preferred_addr),
                                            otel::attr::io_error_type(io),
                                            otel::attr::io_error_code(io),
                                        ],
                                    );
                                }

                                // We use the inbound_tx channel to send the error back to the main thread.
                                if inbound_tx.send_async(Err(e)).await.is_err() {
                                    tracing::debug!(
                                        "Channel for inbound datagrams closed; exiting UDP thread"
                                    );
                                    break;
                                }
                            };
                        }

                        tracing::debug!(
                            "Channel for outbound datagrams closed; exiting UDP thread"
                        );
                    }
                });
                let receive = runtime.spawn(async move {
                    loop {
                        tokio::task::yield_now().await;

                        let result = socket.recv_from().await;

                        if let Some(io) = result
                            .as_ref()
                            .err()
                            .and_then(|e| e.downcast_ref::<io::Error>())
                        {
                            io_error_counter.add(
                                1,
                                &[
                                    otel::attr::network_io_direction_receive(),
                                    otel::attr::network_type_for_addr(preferred_addr),
                                    otel::attr::io_error_type(io),
                                    otel::attr::io_error_code(io),
                                ],
                            );
                        }

                        if inbound_tx.send_async(result).await.is_err() {
                            tracing::debug!(
                                "Channel for inbound datagrams closed; exiting UDP thread"
                            );
                            break;
                        }
                    }
                });

                let _ = error_tx.send(Ok(()));

                runtime.block_on(futures::future::select(send, receive));
            })?;

        error_rx.recv().map_err(io::Error::other)??;

        Ok(Self {
            thread_name,
            join_handle,
            channels: Some(Channels {
                outbound_tx: outbound_tx.into_sink(),
                inbound_rx: inbound_rx.into_stream(),
            }),
        })
    }

    fn poll_send_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        ready!(self.channels_mut()?.outbound_tx.poll_ready_unpin(cx))
            .map_err(|_| UdpSocketThreadStopped)?;

        Poll::Ready(Ok(()))
    }

    fn send(&mut self, datagram: DatagramOut) -> Result<()> {
        self.channels_mut()?
            .outbound_tx
            .start_send_unpin(datagram)
            .map_err(|_| UdpSocketThreadStopped)?;

        Ok(())
    }

    fn poll_recv_from(&mut self, cx: &mut Context<'_>) -> Poll<Result<DatagramSegmentIter>> {
        let iter = ready!(self.channels_mut()?.inbound_rx.poll_next_unpin(cx))
            .ok_or(UdpSocketThreadStopped)?;

        Poll::Ready(iter)
    }

    fn channels_mut(&mut self) -> Result<&mut Channels> {
        self.channels.as_mut().context("Missing channels")
    }
}

impl Drop for ThreadedUdpSocket {
    fn drop(&mut self) {
        let start = Instant::now();

        let _ = self.channels.take();

        const TIMEOUT: Duration = Duration::from_millis(500);

        while !self.join_handle.is_finished() {
            let elapsed = start.elapsed();

            if elapsed > TIMEOUT {
                tracing::debug!(name = %self.thread_name, "Thread did not stop within {TIMEOUT:?}");
                return;
            }
        }

        tracing::debug!(name = %self.thread_name, duration = ?start.elapsed(), "Background thread stopped");
    }
}

fn listen(
    sf: Arc<dyn SocketFactory<UdpSocket>>,
    addresses: &[SocketAddr],
) -> io::Result<UdpSocket> {
    let mut last_err = None;

    for addr in addresses {
        match sf.bind(*addr) {
            Ok(s) => return Ok(s),
            Err(e) => {
                tracing::debug!(%addr, "Failed to listen on UDP socket: {e}");

                last_err = Some(e);
            }
        };
    }

    Err(last_err.unwrap_or_else(|| io::Error::other("No addresses to listen on")))
}

#[derive(thiserror::Error, Debug)]
#[error("UDP socket thread stopped")]
pub struct UdpSocketThreadStopped;
