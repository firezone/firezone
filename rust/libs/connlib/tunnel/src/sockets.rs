use crate::otel;
use anyhow::{Context as _, ErrorExt as _, Result};
use futures::{SinkExt, ready};
use gat_lending_iterator::LendingIterator;
use socket_factory::{DatagramIn, DatagramSegmentIter, SocketFactory, UdpSocket};
use socket_factory::{DatagramOut, PerfUdpSocket};
use std::env::VarError;
use std::time::{Duration, Instant};
use std::{
    io,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    sync::Arc,
    task::{Context, Poll, Waker},
};
use tokio::sync::mpsc;
use tokio_util::sync::PollSender;

const DEFAULT_LISTEN_PORT: u16 = EPHEMERAL_PORT_RANGE_START + FIRE;
const EPHEMERAL_PORT_RANGE_START: u16 = 49152;
const FIRE: u16 = 3473; // "FIRE" when typed on a phone pad.
/// How many outgoing UDP batches the send task drains from a socket's channel per wakeup.
///
/// The outbound queue is sized as a small multiple of this (see [`QUEUE_SIZE`]), and every queued
/// batch pins a GSO buffer, so a smaller limit means less retained send memory. Mobile clients talk to
/// only a handful of peers at once, so they drain - and therefore queue - fewer batches at a time.
const UDP_SEND_BATCH_LIMIT: usize = cfg_select! {
    target_os = "ios" => { 3 }
    target_os = "android" => { 3 }
    _ => { 32 }
};

/// How many incoming UDP batches the main thread drains from a socket's channel per poll.
///
/// Each batch held on the main thread pins up to [`socket_factory::MAX_RECV_BATCH_MEMORY`], which
/// varies hugely with GRO. Android coalesces up to 64 datagrams into every buffer (~2.5 MB per batch),
/// so it drains a single batch per poll to keep the inbound budget tight - one batch already carries up
/// to `BATCH_SIZE * 64` datagrams. iOS has no GRO, so a batch holds only `BATCH_SIZE` datagrams; it
/// drains many more per poll to reach a comparable throughput, which its tiny (~45 KB) batches make
/// cheap. Desktop has GRO and no tight memory cap, so a moderate limit already saturates it.
const UDP_RECV_BATCH_LIMIT: usize = cfg_select! {
    target_os = "ios" => { 32 }
    target_os = "android" => { 1 }
    _ => { 8 }
};

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
    ) -> Poll<impl for<'a> LendingIterator<Item<'a> = DatagramIn<'a>> + use<>> {
        let mut iter = PacketIter::new();

        if let Some(Poll::Ready(packets)) = self.socket_v4.as_mut().map(|s| s.poll_recv_from(cx)) {
            iter.ip4 = Some(packets);
        }

        if let Some(Poll::Ready(packets)) = self.socket_v6.as_mut().map(|s| s.poll_recv_from(cx)) {
            iter.ip6 = Some(packets);
        }

        if iter.is_empty() {
            return Poll::Pending;
        }

        Poll::Ready(iter)
    }

    pub fn poll_error(&mut self, cx: &mut Context<'_>) -> Poll<anyhow::Error> {
        if let Some(socket) = self.socket_v4.as_mut()
            && let Poll::Ready(e) = socket.poll_error(cx)
        {
            return Poll::Ready(e);
        }

        if let Some(socket) = self.socket_v6.as_mut()
            && let Poll::Ready(e) = socket.poll_error(cx)
        {
            return Poll::Ready(e);
        }

        Poll::Pending
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

/// Chains up to [`UDP_RECV_BATCH_LIMIT`] datagram batches from a single `poll` into one iterator.
///
/// A linked list (not a `Vec`) so `next` can fall back from the drained `current` batch to `rest` as
/// separate fields — the disjoint borrow that lets a runtime-length chain of lending iterators
/// compile on stable Rust.
struct ChainedDatagrams {
    current: DatagramSegmentIter,
    rest: Option<Box<ChainedDatagrams>>,
}

impl ChainedDatagrams {
    fn new(batches: Vec<DatagramSegmentIter>) -> Option<Self> {
        let mut rest = None;

        for current in batches.into_iter().rev() {
            rest = Some(Box::new(ChainedDatagrams { current, rest }));
        }

        rest.map(|boxed| *boxed)
    }
}

impl LendingIterator for ChainedDatagrams {
    type Item<'a> = DatagramIn<'a>;

    fn next(&mut self) -> Option<Self::Item<'_>> {
        self.current.next().or_else(|| self.rest.as_mut()?.next())
    }
}

/// How big the queue for outgoing UDP batches and socket errors is at most.
///
/// Every queued [`DatagramOut`] owns a GSO buffer of [`crate::io::GSO_BUFFER_SIZE`] bytes that it
/// pins until the send task drains it - and, because the buffer pool never shrinks, for the rest of
/// the session once a backlog has ever built up. We therefore size it as two drains' worth of
/// [`UDP_SEND_BATCH_LIMIT`]: deep enough to keep the send task fed, shallow enough that a transient
/// send backlog cannot balloon memory. The platform split lives entirely in [`UDP_SEND_BATCH_LIMIT`].
/// See [`MAX_UDP_OUTBOUND_QUEUE_MEMORY`] for the resulting bound.
const QUEUE_SIZE: usize = 2 * UDP_SEND_BATCH_LIMIT;

/// How many incoming UDP batches a socket's channel holds at most.
///
/// One drain's worth (see [`UDP_RECV_BATCH_LIMIT`]) - unlike the outbound [`QUEUE_SIZE`], which holds
/// two. On Android each batch pins [`socket_factory::MAX_RECV_BATCH_MEMORY`] (~2.5 MB with GRO), so a
/// single batch already buffers thousands of datagrams and queueing more than one drain's worth would
/// blow the mobile budget. See [`MAX_UDP_INBOUND_QUEUE_MEMORY`].
const INBOUND_QUEUE_SIZE: usize = UDP_RECV_BATCH_LIMIT;

/// Worst-case memory pinned by the outbound UDP datagram queues.
///
/// connlib runs one socket thread per address family (IPv4 + IPv6), each with an outbound queue of
/// [`QUEUE_SIZE`] datagrams (hence the `2 *`). Every [`DatagramOut`] owns a GSO buffer from the
/// [`UdpGsoQueue`](crate::io::UdpGsoQueue)'s pool, allocated at [`crate::io::GSO_BUFFER_SIZE`]
/// regardless of how full it is. That pool never shrinks, so a send backlog that ever fills these
/// queues pins this much memory for the rest of the session.
const MAX_UDP_OUTBOUND_QUEUE_MEMORY: usize =
    2 * QUEUE_SIZE * (size_of::<DatagramOut>() + crate::io::GSO_BUFFER_SIZE);

/// Worst-case memory pinned by the inbound UDP receive path while in flight.
///
/// Per address family (hence `2 *`), receive batches can be held in three places at once: up to
/// [`INBOUND_QUEUE_SIZE`] queued in the channel, up to [`UDP_RECV_BATCH_LIMIT`] drained onto the main
/// thread, and one being filled by the receive task. Each batch pins
/// [`socket_factory::MAX_RECV_BATCH_MEMORY`], which on Linux / Android sizes every buffer for a full
/// 64-datagram GRO batch - the term that dominates here and the reason the depths above are shallow.
const MAX_UDP_INBOUND_QUEUE_MEMORY: usize =
    2 * (INBOUND_QUEUE_SIZE + UDP_RECV_BATCH_LIMIT + 1) * socket_factory::MAX_RECV_BATCH_MEMORY;

#[cfg(any(target_os = "ios", target_os = "android"))]
const _: () = {
    assert!(MAX_UDP_OUTBOUND_QUEUE_MEMORY <= 1024 * 1024);
    assert!(MAX_UDP_INBOUND_QUEUE_MEMORY <= 16 * 1024 * 1024);
};
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const _: () = {
    assert!(MAX_UDP_OUTBOUND_QUEUE_MEMORY <= 20 * 1024 * 1024);
    assert!(MAX_UDP_INBOUND_QUEUE_MEMORY <= 128 * 1024 * 1024);
};

struct ThreadedUdpSocket {
    thread_name: String,
    join_handle: std::thread::JoinHandle<()>,
    channels: Option<Channels>,
}

struct Channels {
    outbound_tx: PollSender<DatagramOut>,
    inbound_rx: mpsc::Receiver<DatagramSegmentIter>,
    /// Send/receive errors, plus a final [`UdpSocketThreadStopped`] when a thread dies.
    error_rx: mpsc::Receiver<anyhow::Error>,
}

impl ThreadedUdpSocket {
    fn new(sf: Arc<dyn SocketFactory<UdpSocket>>, preferred_addr: SocketAddr) -> io::Result<Self> {
        let (outbound_tx, mut outbound_rx) = mpsc::channel(QUEUE_SIZE);
        let (inbound_tx, inbound_rx) = mpsc::channel(INBOUND_QUEUE_SIZE);
        let (error_tx, error_rx) = mpsc::channel(QUEUE_SIZE);
        let (startup_tx, startup_rx) = std::sync::mpsc::sync_channel(0);

        tokio::spawn(otel_instruments::periodic_queue_length(
            outbound_tx.downgrade(),
            [
                otel::attr::queue_item_gso_batch(),
                otel::attr::network_type_for_addr(preferred_addr),
            ],
        ));
        tokio::spawn(otel_instruments::periodic_queue_length(
            inbound_tx.downgrade(),
            [
                otel::attr::queue_item_gro_batch(),
                otel::attr::network_type_for_addr(preferred_addr),
            ],
        ));

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
                        let _ = startup_tx.send(Err(e));
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
                        let _ = startup_tx.send(Err(e));
                        return;
                    }
                };

                let io_error_counter = otel_instruments::network_errors();

                let send_buffer_size = read_end_var_usize("FIREZONE_UDP_SEND_BUFFER_SIZE")
                    .inspect_err(|e| {
                        tracing::debug!("Failed to read `FIREZONE_UDP_SEND_BUFFER_SIZE`: {e}")
                    })
                    .unwrap_or_default()
                    .unwrap_or(socket_factory::SEND_BUFFER_SIZE);
                let recv_buffer_size = read_end_var_usize("FIREZONE_UDP_RECV_BUFFER_SIZE")
                    .inspect_err(|e| {
                        tracing::debug!("Failed to read `FIREZONE_UDP_RECV_BUFFER_SIZE`: {e}")
                    })
                    .unwrap_or_default()
                    .unwrap_or(socket_factory::RECV_BUFFER_SIZE);

                socket.set_buffer_sizes(send_buffer_size, recv_buffer_size);

                let socket = Arc::new(socket);

                let send = runtime.spawn({
                    let io_error_counter = io_error_counter.clone();
                    let error_tx = error_tx.clone();
                    let socket = socket.clone();

                    let mut pending_datagrams = Vec::with_capacity(UDP_SEND_BATCH_LIMIT);

                    async move {
                        loop {
                            let num_batches = outbound_rx
                                .recv_many(&mut pending_datagrams, UDP_SEND_BATCH_LIMIT)
                                .await;

                            if num_batches == 0 {
                                tracing::debug!(
                                    "Channel for outbound datagrams closed; exiting UDP send task"
                                );
                                return;
                            }

                            for datagram in pending_datagrams.drain(..) {
                                if let Err(e) = socket.send(datagram).await {
                                    if let Some(io) = e.any_downcast_ref::<io::Error>() {
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

                                    // Dedicated channel so errors can't hold up received datagrams.
                                    if error_tx.send(e).await.is_err() {
                                        tracing::debug!(
                                            "Channel for errors closed; exiting UDP send task"
                                        );
                                        return;
                                    }
                                };
                            }
                        }
                    }
                });
                let receive = runtime.spawn({
                    let error_tx = error_tx.clone();

                    async move {
                        loop {
                            let datagrams = match socket.recv_from().await {
                                Ok(datagrams) => datagrams,
                                Err(e) => {
                                    if let Some(io) = e.any_downcast_ref::<io::Error>() {
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

                                    if error_tx.send(e).await.is_err() {
                                        tracing::debug!(
                                            "Channel for errors closed; exiting UDP recv task"
                                        );
                                        return;
                                    }

                                    continue;
                                }
                            };

                            if inbound_tx.send(datagrams).await.is_err() {
                                tracing::debug!(
                                    "Channel for inbound datagrams closed; exiting UDP recv task"
                                );
                                return;
                            }
                        }
                    }
                });

                let _ = startup_tx.send(Ok(()));

                runtime.block_on(async move {
                    futures::future::select(send, receive).await;

                    // A stopped task tears down the runtime; report it so `Io` shuts down.
                    let _ = error_tx.send(UdpSocketThreadStopped.into()).await;
                });
            })?;

        startup_rx.recv().map_err(io::Error::other)??;

        Ok(Self {
            thread_name,
            join_handle,
            channels: Some(Channels {
                outbound_tx: PollSender::new(outbound_tx),
                inbound_rx,
                error_rx,
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

    fn poll_recv_from(&mut self, cx: &mut Context<'_>) -> Poll<ChainedDatagrams> {
        let Some(channels) = self.channels.as_mut() else {
            return Poll::Pending;
        };

        let mut batches = Vec::with_capacity(UDP_RECV_BATCH_LIMIT);
        ready!(
            channels
                .inbound_rx
                .poll_recv_many(cx, &mut batches, UDP_RECV_BATCH_LIMIT)
        );

        let Some(datagrams) = ChainedDatagrams::new(batches) else {
            // An empty read means a closed channel, i.e. the thread stopped (reported via
            // `poll_error`). `Pending` avoids dropping the other socket's datagrams; no waker on
            // close, since we'll be shutting down anyway.
            return Poll::Pending;
        };

        Poll::Ready(datagrams)
    }

    fn poll_error(&mut self, cx: &mut Context<'_>) -> Poll<anyhow::Error> {
        let Some(channels) = self.channels.as_mut() else {
            return Poll::Pending;
        };

        let Some(error) = ready!(channels.error_rx.poll_recv(cx)) else {
            return Poll::Pending;
        };

        Poll::Ready(error)
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
) -> io::Result<PerfUdpSocket> {
    let mut last_err = None;

    for addr in addresses {
        match sf.bind(*addr).and_then(|s| s.into_perf()) {
            Ok(s) => return Ok(s),
            Err(e) => {
                tracing::debug!(%addr, "Failed to listen on UDP socket: {e}");

                last_err = Some(e);
            }
        };
    }

    Err(last_err.unwrap_or_else(|| io::Error::other("No addresses to listen on")))
}

fn read_end_var_usize(name: &str) -> Result<Option<usize>> {
    let var = match std::env::var(name) {
        Ok(var) => var,
        Err(VarError::NotPresent) => return Ok(None),
        Err(e @ VarError::NotUnicode(_)) => return Err(anyhow::Error::new(e)),
    };

    let var = var.parse().context("Failed to parse as usize")?;

    Ok(Some(var))
}

#[derive(thiserror::Error, Debug)]
#[error("UDP socket thread stopped")]
pub struct UdpSocketThreadStopped;
