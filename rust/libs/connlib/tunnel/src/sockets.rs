use crate::otel;
use crate::packet_counts::UdpPacketCounts;
use anyhow::{Context as _, ErrorExt as _, Result};
use futures::{FutureExt as _, future::BoxFuture, ready};
use ip_packet::IpVersion;
use opentelemetry::metrics::Counter;
use socket_factory::{
    DatagramBatch, DatagramIn, DatagramOut, PerfUdpSocket, SocketFactory, UdpSocket,
};
use std::collections::VecDeque;
use std::env::VarError;
use std::time::{Duration, Instant};
use std::{
    io,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    sync::{Arc, Mutex, PoisonError},
    task::{Context, Poll},
};
use tokio::sync::mpsc::{
    self,
    error::{SendError, TrySendError},
};
use tokio::sync::oneshot;

const DEFAULT_LISTEN_PORT: u16 = EPHEMERAL_PORT_RANGE_START + FIRE;
const EPHEMERAL_PORT_RANGE_START: u16 = 49152;
const FIRE: u16 = 3473; // "FIRE" when typed on a phone pad.
/// How many outgoing UDP batches the send task drains from a socket's channel per wakeup.
///
/// The outbound queue is sized as a small multiple of this (see [`QUEUE_SIZE`]), and every queued
/// item pins the GSO buffers of its trains, so a smaller limit means less retained send memory.
/// Mobile clients talk to only a handful of peers at once, so they drain - and therefore queue -
/// fewer batches at a time.
const UDP_SEND_BATCH_LIMIT: usize = cfg_select! {
    target_os = "ios" => { 3 }
    target_os = "android" => { 3 }
    _ => { 32 }
};

/// How many incoming UDP batches the main thread drains from a socket's channel per poll.
///
/// A batch is one `recv_from`: `quinn-udp` reads up to `BATCH_SIZE` (32 on unix) datagrams in a single
/// syscall, and where GRO is available the kernel additionally coalesces up to 64 datagrams into each.
/// So both the memory a batch pins ([`socket_factory::MAX_RECV_BATCH_MEMORY`]) and the datagrams it
/// carries swing with GRO: `1316 * 32 * 64` ~ 2.5 MB on Android (GRO), `1316 * 32` ~ 45 KB on Apple.
/// Apple - iOS and macOS alike - has no GRO (`recvmsg_x` only batches individual datagrams), so it
/// drains many of these small batches per poll to sustain throughput, which is cheap. Android's GRO
/// batches are large, so it drains a single one per poll to hold the inbound budget down. Other desktop
/// platforms aren't memory-capped, so a moderate limit already saturates them.
const UDP_RECV_BATCH_LIMIT: usize = cfg_select! {
    target_os = "ios" => { 32 }
    target_os = "macos" => { 32 }
    target_os = "android" => { 1 }
    _ => { 8 }
};

const UNSPECIFIED_V4_SOCKET: SocketAddrV4 =
    SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, DEFAULT_LISTEN_PORT);
const UNSPECIFIED_V6_SOCKET: SocketAddrV6 =
    SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, DEFAULT_LISTEN_PORT, 0, 0);

/// Datagrams received from the UDP sockets, in the batches their threads read them in.
///
/// Dropping it hands the emptied vector back to [`Sockets`] for the next receive.
pub(crate) struct ReceivedDatagrams {
    batches: Vec<DatagramBatch>,
    spare: Arc<Mutex<Vec<DatagramBatch>>>,
}

impl ReceivedDatagrams {
    /// How many datagrams were received, counting every segment of a coalesced one.
    pub fn len(&self) -> usize {
        self.batches.iter().map(DatagramBatch::len).sum()
    }

    /// Moves out every received datagram, in the order the sockets received them.
    pub fn drain(&mut self) -> impl Iterator<Item = DatagramIn> + '_ {
        self.batches.iter_mut().flat_map(|batch| batch.drain())
    }
}

impl Drop for ReceivedDatagrams {
    fn drop(&mut self) {
        self.batches.clear();

        *self.spare.lock().unwrap_or_else(PoisonError::into_inner) =
            std::mem::take(&mut self.batches);
    }
}

/// Room for one item in a UDP socket's channel.
enum Reserved<'a> {
    /// Taken right away from a channel with room.
    Borrowed(mpsc::Permit<'a, Outbound>),
    /// Waited for on a full channel.
    Owned(mpsc::OwnedPermit<Outbound>),
}

impl Reserved<'_> {
    fn send(self, outbound: Outbound) {
        match self {
            Reserved::Borrowed(permit) => permit.send(outbound),
            Reserved::Owned(permit) => {
                permit.send(outbound);
            }
        }
    }
}

pub(crate) struct Sockets {
    /// Binds the sockets; sockets without one are kept as they are across [`Sockets::rebind`].
    socket_factory: Option<Arc<dyn SocketFactory<UdpSocket>>>,
    socket_v4: Option<ThreadedUdpSocket>,
    socket_v6: Option<ThreadedUdpSocket>,

    /// Items waiting for room in the channel of the IPv4 / IPv6 socket. Once one waits, every
    /// later item for that socket queues behind it, so a socket's items go out in the order they
    /// were sent.
    overflow_v4: VecDeque<Outbound>,
    overflow_v6: VecDeque<Outbound>,
    /// Bind failures, surfaced through [`Sockets::poll_error`] alongside runtime socket errors.
    bind_errors: VecDeque<anyhow::Error>,
    packet_counter: Counter<u64>,

    /// The vector to receive the next batches into, unless it is lent out to a [`ReceivedDatagrams`].
    recv_batches: Option<Vec<DatagramBatch>>,
    /// Where a dropped [`ReceivedDatagrams`] returns the vector.
    returned_recv_batches: Arc<Mutex<Vec<DatagramBatch>>>,
}

impl Sockets {
    /// Creates sockets for both families, bound to the unspecified address.
    pub fn new(socket_factory: Arc<dyn SocketFactory<UdpSocket>>) -> Self {
        let mut sockets = Self::without_sockets(Some(socket_factory));
        sockets.rebind();

        sockets
    }

    fn without_sockets(socket_factory: Option<Arc<dyn SocketFactory<UdpSocket>>>) -> Self {
        Self {
            socket_factory,
            socket_v4: None,
            socket_v6: None,
            overflow_v4: VecDeque::new(),
            overflow_v6: VecDeque::new(),
            bind_errors: VecDeque::new(),
            packet_counter: otel_instruments::network_packets(),
            recv_batches: Some(Vec::with_capacity(2 * UDP_RECV_BATCH_LIMIT)),
            returned_recv_batches: Arc::default(),
        }
    }

    /// Drops the items waiting for room and binds new sockets through the socket factory.
    pub fn rebind(&mut self) {
        self.overflow_v4.clear();
        self.overflow_v6.clear();

        let Some(socket_factory) = self.socket_factory.clone() else {
            return;
        };

        self.socket_v4 = None;
        self.socket_v6 = None;

        self.socket_v4 = self.bind(&socket_factory, SocketAddr::V4(UNSPECIFIED_V4_SOCKET));
        self.socket_v6 = self.bind(&socket_factory, SocketAddr::V6(UNSPECIFIED_V6_SOCKET));
    }

    fn bind(
        &mut self,
        socket_factory: &Arc<dyn SocketFactory<UdpSocket>>,
        addr: SocketAddr,
    ) -> Option<ThreadedUdpSocket> {
        match ThreadedUdpSocket::new(socket_factory.clone(), addr) {
            Ok(socket) => Some(socket),
            Err(e) => {
                // A family we cannot bind is survivable on its own - the other one carries the
                // session - so the event-loop decides what a failure means instead of us.
                self.bind_errors.push_back(
                    anyhow::Error::new(e).context(format!("Failed to bind UDP socket on {addr}")),
                );

                None
            }
        }
    }

    /// Sends the items waiting for room, resolving once none are left.
    pub fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        let v4 = poll_flush_overflow(self.socket_v4.as_mut(), &mut self.overflow_v4, "IPv4", cx);
        let v6 = poll_flush_overflow(self.socket_v6.as_mut(), &mut self.overflow_v6, "IPv6", cx);

        match (v4, v6) {
            (Poll::Ready(Err(e)), _) | (_, Poll::Ready(Err(e))) => Poll::Ready(Err(e)),
            (Poll::Ready(Ok(())), Poll::Ready(Ok(()))) => Poll::Ready(Ok(())),
            (Poll::Pending, _) | (_, Poll::Pending) => Poll::Pending,
        }
    }

    /// Sends a datagram the main thread encrypted, or a control message.
    ///
    /// Failures are returned by [`Sockets::poll_flush`].
    pub fn send_ready(&mut self, transmit: snownet::Transmit) {
        UdpPacketCounts::transmit(&self.packet_counter).record(&transmit.payload);

        let version = match transmit.dst {
            SocketAddr::V4(_) => IpVersion::V4,
            SocketAddr::V6(_) => IpVersion::V6,
        };
        let datagram = DatagramOut {
            src: transmit.src,
            dst: transmit.dst,
            segment_size: transmit.payload.len(),
            packet: transmit.payload,
            ecn: transmit.ecn,
        };

        self.queue(version, Outbound::Ready(datagram));
    }

    /// Sends datagrams that are still being encrypted on the socket for `version`, in order.
    ///
    /// Failures are returned by [`Sockets::poll_flush`].
    pub fn send_pending(&mut self, version: IpVersion, datagrams: PendingDatagrams) {
        self.queue(version, Outbound::Pending(datagrams));
    }

    /// Queues `outbound` behind the items still waiting for room in its socket, sending it right
    /// away if there are none and the socket has room.
    fn queue(&mut self, version: IpVersion, outbound: Outbound) {
        let (socket, overflow) = match version {
            IpVersion::V4 => (self.socket_v4.as_ref(), &mut self.overflow_v4),
            IpVersion::V6 => (self.socket_v6.as_ref(), &mut self.overflow_v6),
        };

        if overflow.is_empty()
            && let Some(reserved) = socket.and_then(ThreadedUdpSocket::try_reserve)
        {
            reserved.send(outbound);
            return;
        }

        overflow.push_back(outbound);
    }

    /// Polls for batches of received UDP datagrams, at most [`UDP_RECV_BATCH_LIMIT`] per socket.
    pub fn poll_recv_from(&mut self, cx: &mut Context<'_>) -> Poll<ReceivedDatagrams> {
        let mut batches = self.recv_batches.take().unwrap_or_else(|| {
            std::mem::take(
                &mut self
                    .returned_recv_batches
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner),
            )
        });

        if let Some(socket) = self.socket_v4.as_mut() {
            socket.poll_recv_from(cx, &mut batches);
        }

        if let Some(socket) = self.socket_v6.as_mut() {
            socket.poll_recv_from(cx, &mut batches);
        }

        if batches.is_empty() {
            self.recv_batches = Some(batches);

            return Poll::Pending;
        }

        Poll::Ready(ReceivedDatagrams {
            batches,
            spare: self.returned_recv_batches.clone(),
        })
    }

    pub fn poll_error(&mut self, cx: &mut Context<'_>) -> Poll<anyhow::Error> {
        if let Some(error) = self.bind_errors.pop_front() {
            return Poll::Ready(error);
        }

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

/// Sends the items waiting for room in `socket`'s channel, resolving once none are left.
///
/// Items for a socket we do not have are dropped.
fn poll_flush_overflow(
    socket: Option<&mut ThreadedUdpSocket>,
    overflow: &mut VecDeque<Outbound>,
    name: &str,
    cx: &mut Context<'_>,
) -> Poll<Result<()>> {
    let Some(socket) = socket else {
        if overflow.is_empty() {
            return Poll::Ready(Ok(()));
        }

        overflow.clear();

        return Poll::Ready(Err(io::Error::new(
            io::ErrorKind::NotConnected,
            format!("failed to send packets: no {name} socket"),
        )
        .into()));
    };

    while !overflow.is_empty() {
        let reserved = ready!(socket.poll_reserve(cx));

        let Some(outbound) = overflow.pop_front() else {
            break;
        };

        // An item we cannot reserve room for is dropped.
        reserved?.send(outbound);
    }

    Poll::Ready(Ok(()))
}

/// What a UDP socket thread sends, in queue order.
pub(crate) enum Outbound {
    Ready(DatagramOut),
    Pending(PendingDatagrams),
}

/// Datagrams still being encrypted by the crypto workers, in the order to send them.
///
/// A worker drops the sender if there is nothing to send.
pub(crate) type PendingDatagrams = Vec<oneshot::Receiver<DatagramOut>>;

/// How big the queue for outgoing UDP items and socket errors is at most.
///
/// Every queued item pins the GSO buffers of up to one TUN batch of packets until the send task has
/// sent it - and, because the buffer pools never shrink, for the rest of the session once a backlog
/// has ever built up. We therefore size it as two drains' worth of [`UDP_SEND_BATCH_LIMIT`]: deep
/// enough to keep the send task fed, shallow enough that a transient send backlog cannot balloon
/// memory. The platform split lives entirely in [`UDP_SEND_BATCH_LIMIT`].
/// See [`MAX_UDP_OUTBOUND_QUEUE_MEMORY`] for the resulting bound.
const QUEUE_SIZE: usize = 2 * UDP_SEND_BATCH_LIMIT;

/// How many incoming UDP batches a socket's channel holds at most.
///
/// One drain's worth (see [`UDP_RECV_BATCH_LIMIT`]) - unlike the outbound [`QUEUE_SIZE`], which holds
/// two. On Android each batch pins [`socket_factory::MAX_RECV_BATCH_MEMORY`] (~2.5 MB with GRO), so a
/// single batch already buffers thousands of datagrams and queueing more than one drain's worth would
/// blow the mobile budget. See [`MAX_UDP_INBOUND_QUEUE_MEMORY`].
const INBOUND_QUEUE_SIZE: usize = UDP_RECV_BATCH_LIMIT;

/// Worst-case memory pinned by the outbound UDP send path while in flight.
///
/// Per address family (hence `2 *`), items can be held in three places at once: up to
/// [`QUEUE_SIZE`] in the channel, one waiting for room in it, since the TUN device is only read
/// while nothing waits, and up to [`UDP_SEND_BATCH_LIMIT`] drained by the send task.
/// An item carries at most one TUN batch of packets, so at most as many trains, each with a
/// [`DatagramOut`]. A train's GSO buffer is at most one packet buffer or twice its length, so at
/// most twice [`ip_packet::MAX_FZ_PAYLOAD`] per packet.
///
/// Every size class pools its buffers separately, so backlogs of differently sized trains can
/// leave more than this pooled.
const MAX_UDP_OUTBOUND_QUEUE_MEMORY: usize = 2
    * (QUEUE_SIZE + 1 + UDP_SEND_BATCH_LIMIT)
    * tun::MAX_BATCH_SIZE
    * (size_of::<DatagramOut>() + 2 * ip_packet::MAX_FZ_PAYLOAD);

/// Worst-case memory pinned by the inbound UDP receive path while in flight.
///
/// Per address family (hence `2 *`), receive batches can be held in three places at once: up to
/// [`INBOUND_QUEUE_SIZE`] queued in the channel, up to [`UDP_RECV_BATCH_LIMIT`] drained onto the main
/// thread, whose buffers move into decrypt jobs, and one being filled by the receive task. Each batch
/// pins [`socket_factory::MAX_RECV_BATCH_MEMORY`], which on Linux / Android sizes every buffer for a
/// full 64-datagram GRO batch - the term that dominates here and the reason the depths above are
/// shallow. On top, the jobs of earlier drains may still await decryption
/// ([`MAX_DECRYPT_BACKLOG_MEMORY`](crate::io::MAX_DECRYPT_BACKLOG_MEMORY)).
const MAX_UDP_INBOUND_QUEUE_MEMORY: usize =
    2 * (INBOUND_QUEUE_SIZE + UDP_RECV_BATCH_LIMIT + 1) * socket_factory::MAX_RECV_BATCH_MEMORY
        + crate::io::MAX_DECRYPT_BACKLOG_MEMORY;

#[cfg(any(target_os = "ios", target_os = "android"))]
const _: () = {
    assert!(MAX_UDP_OUTBOUND_QUEUE_MEMORY <= 2 * 1024 * 1024);
    assert!(MAX_UDP_INBOUND_QUEUE_MEMORY <= 16 * 1024 * 1024);
};
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const _: () = {
    assert!(MAX_UDP_OUTBOUND_QUEUE_MEMORY <= 64 * 1024 * 1024);
    assert!(MAX_UDP_INBOUND_QUEUE_MEMORY <= 128 * 1024 * 1024);
};

struct ThreadedUdpSocket {
    thread_name: String,
    join_handle: Option<std::thread::JoinHandle<()>>,
    main_thread_ends: Option<MainThreadEnds>,
}

/// The ends of a socket's channels that the main thread holds.
struct MainThreadEnds {
    outbound_tx: mpsc::Sender<Outbound>,
    /// Waits for room in the outbound channel once it is full.
    waiting_for_room:
        Option<BoxFuture<'static, Result<mpsc::OwnedPermit<Outbound>, SendError<()>>>>,
    inbound_rx: mpsc::Receiver<DatagramBatch>,
    /// Send/receive errors, plus a final [`UdpSocketThreadStopped`] when a thread dies.
    error_rx: mpsc::Receiver<anyhow::Error>,
}

/// The ends of a socket's channels that its thread holds.
pub struct SocketThreadEnds {
    pub(crate) outbound_rx: mpsc::Receiver<Outbound>,
    pub(crate) inbound_tx: mpsc::Sender<DatagramBatch>,
    pub(crate) error_tx: mpsc::Sender<anyhow::Error>,
}

fn channels() -> (MainThreadEnds, SocketThreadEnds) {
    let (outbound_tx, outbound_rx) = mpsc::channel(QUEUE_SIZE);
    let (inbound_tx, inbound_rx) = mpsc::channel(INBOUND_QUEUE_SIZE);
    let (error_tx, error_rx) = mpsc::channel(QUEUE_SIZE);

    let main_thread_ends = MainThreadEnds {
        outbound_tx,
        waiting_for_room: None,
        inbound_rx,
        error_rx,
    };
    let socket_thread_ends = SocketThreadEnds {
        outbound_rx,
        inbound_tx,
        error_tx,
    };

    (main_thread_ends, socket_thread_ends)
}

impl ThreadedUdpSocket {
    fn new(sf: Arc<dyn SocketFactory<UdpSocket>>, preferred_addr: SocketAddr) -> io::Result<Self> {
        let (
            main_thread_ends,
            SocketThreadEnds {
                mut outbound_rx,
                inbound_tx,
                error_tx,
            },
        ) = channels();
        let (startup_tx, startup_rx) = std::sync::mpsc::sync_channel(0);

        tokio::spawn(otel_instruments::periodic_queue_length(
            main_thread_ends.outbound_tx.downgrade(),
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

                    let mut outbound = Vec::with_capacity(UDP_SEND_BATCH_LIMIT);

                    async move {
                        let send = async |datagram| {
                            let Err(e) = socket.send(datagram).await else {
                                return Ok(());
                            };

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
                            error_tx.send(e).await
                        };

                        let reason = 'send: loop {
                            if outbound_rx
                                .recv_many(&mut outbound, UDP_SEND_BATCH_LIMIT)
                                .await
                                == 0
                            {
                                break "Channel for outbound datagrams closed";
                            }

                            for item in outbound.drain(..) {
                                match item {
                                    Outbound::Ready(datagram) => {
                                        if send(datagram).await.is_err() {
                                            break 'send "Channel for errors closed";
                                        }
                                    }
                                    Outbound::Pending(mut datagrams) => {
                                        for datagram in datagrams.drain(..) {
                                            let Ok(datagram) = datagram.await else {
                                                continue;
                                            };

                                            if send(datagram).await.is_err() {
                                                break 'send "Channel for errors closed";
                                            }
                                        }
                                    }
                                }
                            }
                        };

                        tracing::debug!("{reason}; exiting UDP send task");
                    }
                });
                let receive = runtime.spawn({
                    let error_tx = error_tx.clone();

                    async move {
                        loop {
                            let batch = match socket.recv_from().await {
                                Ok(batch) => batch,
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

                            if inbound_tx.send(batch).await.is_err() {
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
            join_handle: Some(join_handle),
            main_thread_ends: Some(main_thread_ends),
        })
    }

    /// Reserves room in the outbound channel for another item.
    fn poll_reserve(&mut self, cx: &mut Context<'_>) -> Poll<Result<Reserved<'_>>> {
        let ends = self.main_thread_ends_mut()?;

        if ends.waiting_for_room.is_none() {
            // Fast path without registering a waker.
            match ends.outbound_tx.try_reserve() {
                Ok(permit) => return Poll::Ready(Ok(Reserved::Borrowed(permit))),
                Err(TrySendError::Full(())) => {}
                Err(TrySendError::Closed(())) => {
                    return Poll::Ready(Err(UdpSocketThreadStopped.into()));
                }
            }
        }

        let outbound_tx = &ends.outbound_tx;
        // This allocates but we only get here when the socket is already full so we will have to suspend anyway.
        let waiting_for_room = ends
            .waiting_for_room
            .get_or_insert_with(|| outbound_tx.clone().reserve_owned().boxed());

        let result = ready!(waiting_for_room.poll_unpin(cx));
        ends.waiting_for_room = None;
        let permit = result.map_err(|_| UdpSocketThreadStopped)?;

        Poll::Ready(Ok(Reserved::Owned(permit)))
    }

    /// Reserves room in the outbound channel for another item if it has some right now.
    fn try_reserve(&self) -> Option<Reserved<'_>> {
        let ends = self.main_thread_ends.as_ref()?;
        let permit = ends.outbound_tx.try_reserve().ok()?;

        Some(Reserved::Borrowed(permit))
    }

    /// Appends the batches received from the socket thread to `batches`, at most
    /// [`UDP_RECV_BATCH_LIMIT`] per call.
    ///
    /// Appending nothing means the channel is either empty or closed, i.e. the thread
    /// stopped (reported via `poll_error`); no waker is registered on close, since
    /// we'll be shutting down anyway.
    fn poll_recv_from(&mut self, cx: &mut Context<'_>, batches: &mut Vec<DatagramBatch>) {
        let Some(ends) = self.main_thread_ends.as_mut() else {
            return;
        };

        let _ = ends
            .inbound_rx
            .poll_recv_many(cx, batches, UDP_RECV_BATCH_LIMIT);
    }

    fn poll_error(&mut self, cx: &mut Context<'_>) -> Poll<anyhow::Error> {
        let Some(ends) = self.main_thread_ends.as_mut() else {
            return Poll::Pending;
        };

        let Some(error) = ready!(ends.error_rx.poll_recv(cx)) else {
            return Poll::Pending;
        };

        Poll::Ready(error)
    }

    fn main_thread_ends_mut(&mut self) -> Result<&mut MainThreadEnds> {
        self.main_thread_ends.as_mut().context("Missing channels")
    }
}

impl Drop for ThreadedUdpSocket {
    fn drop(&mut self) {
        let start = Instant::now();

        let _ = self.main_thread_ends.take();

        let Some(join_handle) = self.join_handle.as_ref() else {
            return;
        };

        const TIMEOUT: Duration = Duration::from_millis(500);

        while !join_handle.is_finished() {
            let elapsed = start.elapsed();

            if elapsed > TIMEOUT {
                tracing::debug!(name = %self.thread_name, "Thread did not stop within {TIMEOUT:?}");
                return;
            }
        }

        tracing::debug!(name = %self.thread_name, duration = ?start.elapsed(), "Background thread stopped");
    }
}

impl Sockets {
    /// Creates sockets for both families without threads; the returned ends play their part.
    pub(crate) fn fake() -> (Self, SocketThreadEnds, SocketThreadEnds) {
        let fake_socket = || {
            let (main_thread_ends, socket_thread_ends) = channels();
            let socket = ThreadedUdpSocket {
                thread_name: "fake".to_owned(),
                join_handle: None,
                main_thread_ends: Some(main_thread_ends),
            };

            (socket, socket_thread_ends)
        };
        let (socket_v4, ends_v4) = fake_socket();
        let (socket_v6, ends_v6) = fake_socket();

        let sockets = Self {
            socket_v4: Some(socket_v4),
            socket_v6: Some(socket_v6),
            ..Self::without_sockets(None)
        };

        (sockets, ends_v4, ends_v6)
    }
}

#[cfg(test)]
#[expect(dead_code, reason = "Not used by any test yet")]
impl Sockets {
    pub(crate) fn remove_v4(&mut self) {
        self.socket_v4 = None;
    }

    pub(crate) fn remove_v6(&mut self) {
        self.socket_v6 = None;
    }

    /// How many items wait for room in the channel of the socket for `version`.
    pub(crate) fn num_waiting(&self, version: IpVersion) -> usize {
        match version {
            IpVersion::V4 => self.overflow_v4.len(),
            IpVersion::V6 => self.overflow_v6.len(),
        }
    }
}

impl SocketThreadEnds {
    /// Hands `batch` to the main thread as if the socket had received it, or returns it if the
    /// channel is full.
    pub fn receive(&self, batch: DatagramBatch) -> Result<(), DatagramBatch> {
        self.inbound_tx
            .try_send(batch)
            .map_err(TrySendError::into_inner)
    }

    /// Appends the datagrams the main thread sent to `sent`, in order.
    ///
    /// Datagrams the crypto workers have yet to encrypt are skipped, so use inline crypto workers.
    pub fn take_sent(&mut self, sent: &mut Vec<DatagramOut>) {
        while let Ok(outbound) = self.outbound_rx.try_recv() {
            match outbound {
                Outbound::Ready(datagram) => sent.push(datagram),
                Outbound::Pending(datagrams) => sent.extend(
                    datagrams
                        .into_iter()
                        .filter_map(|mut datagram| datagram.try_recv().ok()),
                ),
            }
        }
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
