use crate::otel;
use anyhow::{Context as _, Result};
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
const UDP_SEND_BATCH_LIMIT: usize = 16;

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

/// How big the queue for incoming and outgoing UDP batches is at most.
///
/// On mobile platforms, we are memory-constrained and thus cannot afford to process big batches of packets.
const QUEUE_SIZE: usize = {
    if cfg!(any(target_os = "ios", target_os = "android")) {
        10
    } else {
        1000
    }
};

struct ThreadedUdpSocket {
    thread_name: String,
    join_handle: std::thread::JoinHandle<()>,
    channels: Option<Channels>,
}

struct Channels {
    outbound_tx: PollSender<DatagramOut>,
    inbound_rx: mpsc::Receiver<Result<DatagramSegmentIter>>,
}

impl ThreadedUdpSocket {
    fn new(sf: Arc<dyn SocketFactory<UdpSocket>>, preferred_addr: SocketAddr) -> io::Result<Self> {
        let (outbound_tx, outbound_rx) = mpsc::channel(QUEUE_SIZE);
        let (inbound_tx, inbound_rx) = mpsc::channel(QUEUE_SIZE);
        let (error_tx, error_rx) = std::sync::mpsc::sync_channel(0);

        tokio::spawn(otel::metrics::periodic_system_queue_length(
            outbound_tx.downgrade(),
            [
                otel::attr::queue_item_gso_batch(),
                otel::attr::network_type_for_addr(preferred_addr),
            ],
        ));
        tokio::spawn(otel::metrics::periodic_system_queue_length(
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

                let (send_buffer_size, recv_buffer_size) = buffer_sizes();

                if let Err(e) = socket.set_buffer_sizes(send_buffer_size, recv_buffer_size) {
                    tracing::warn!("Failed to set socket buffer sizes: {e}");
                };

                let _ = error_tx.send(Ok(()));

                // The single-socket model (non-Apple) and the connected-socket pool (Apple) share
                // the same channel contract; only the in-thread behaviour differs. On Apple, `socket`
                // is the recv-only listener and all sending happens over a pool of connected sockets.
                #[cfg(any(target_os = "macos", target_os = "ios"))]
                runtime.block_on(connected::run(
                    socket,
                    outbound_rx,
                    inbound_tx,
                    preferred_addr,
                    io_error_counter,
                ));

                #[cfg(not(any(target_os = "macos", target_os = "ios")))]
                runtime.block_on(run_single(
                    socket,
                    outbound_rx,
                    inbound_tx,
                    preferred_addr,
                    io_error_counter,
                ));
            })?;

        error_rx.recv().map_err(io::Error::other)??;

        Ok(Self {
            thread_name,
            join_handle,
            channels: Some(Channels {
                outbound_tx: PollSender::new(outbound_tx),
                inbound_rx,
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
        let iter =
            ready!(self.channels_mut()?.inbound_rx.poll_recv(cx)).ok_or(UdpSocketThreadStopped)?;

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

/// The configured UDP send/receive buffer sizes, falling back to [`socket_factory`]'s defaults.
fn buffer_sizes() -> (usize, usize) {
    let send = read_end_var_usize("FIREZONE_UDP_SEND_BUFFER_SIZE")
        .inspect_err(|e| tracing::debug!("Failed to read `FIREZONE_UDP_SEND_BUFFER_SIZE`: {e}"))
        .unwrap_or_default()
        .unwrap_or(socket_factory::SEND_BUFFER_SIZE);
    let recv = read_end_var_usize("FIREZONE_UDP_RECV_BUFFER_SIZE")
        .inspect_err(|e| tracing::debug!("Failed to read `FIREZONE_UDP_RECV_BUFFER_SIZE`: {e}"))
        .unwrap_or_default()
        .unwrap_or(socket_factory::RECV_BUFFER_SIZE);

    (send, recv)
}

/// The single-socket datapath used on every platform except Apple: one task draining the outbound
/// channel and one task feeding the inbound channel, both over a single shared (unconnected) socket.
#[cfg(not(any(target_os = "macos", target_os = "ios")))]
async fn run_single(
    socket: PerfUdpSocket,
    mut outbound_rx: mpsc::Receiver<DatagramOut>,
    inbound_tx: mpsc::Sender<Result<DatagramSegmentIter>>,
    preferred_addr: SocketAddr,
    io_error_counter: opentelemetry::metrics::Counter<u64>,
) {
    use anyhow::ErrorExt as _;

    let socket = Arc::new(socket);

    let send = tokio::spawn({
        let io_error_counter = io_error_counter.clone();
        let inbound_tx = inbound_tx.clone();
        let socket = socket.clone();

        let mut pending_datagrams = Vec::with_capacity(UDP_SEND_BATCH_LIMIT);

        async move {
            loop {
                let num_batches = outbound_rx
                    .recv_many(&mut pending_datagrams, UDP_SEND_BATCH_LIMIT)
                    .await;

                if num_batches == 0 {
                    tracing::debug!("Channel for outbound datagrams closed; exiting UDP send task");
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

                        // We use the inbound_tx channel to send the error back to the main thread.
                        if inbound_tx.send(Err(e)).await.is_err() {
                            tracing::debug!(
                                "Channel for inbound datagrams closed; exiting UDP send task"
                            );
                            return;
                        }
                    };
                }
            }
        }
    });
    let receive = tokio::spawn(async move {
        loop {
            let result = socket.recv_from().await;

            if let Some(io) = result
                .as_ref()
                .err()
                .and_then(|e| e.any_downcast_ref::<io::Error>())
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

            if inbound_tx.send(result).await.is_err() {
                tracing::debug!("Channel for inbound datagrams closed; exiting UDP recv task");
                return;
            }
        }
    });

    futures::future::select(send, receive).await;
}

/// The connected-socket datapath used on Apple.
///
/// `listener` is a recv-only, unconnected socket bound to the wildcard address. All *sending*
/// happens over a pool of connected sockets (one per `(src_ip, dst)`) that share the listener's
/// port via `SO_REUSEPORT`. This is required on Apple because the batched `sendmsg_x` datapath only
/// works on connected sockets, and only connected sockets surface `ENOBUFS` for back-pressure.
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod connected {
    use super::*;
    use anyhow::ErrorExt as _;
    use std::collections::HashMap;
    use std::net::IpAddr;

    /// Connected sockets idle (no send) for this long are reaped and recreated lazily on the next
    /// send. Comfortably above connlib's keep-alive interval; inbound during a gap is caught by the
    /// listener, so an over-eager reap is self-healing.
    const IDLE_TIMEOUT: Duration = Duration::from_secs(60);
    /// How often we sweep the pool for idle sockets.
    const SWEEP_INTERVAL: Duration = Duration::from_secs(30);

    struct Pooled {
        socket: Arc<PerfUdpSocket>,
        recv_task: tokio::task::AbortHandle,
        last_send: Instant,
    }

    impl Drop for Pooled {
        fn drop(&mut self) {
            self.recv_task.abort();
        }
    }

    pub(super) async fn run(
        listener: PerfUdpSocket,
        mut outbound_rx: mpsc::Receiver<DatagramOut>,
        inbound_tx: mpsc::Sender<Result<DatagramSegmentIter>>,
        preferred_addr: SocketAddr,
        io_error_counter: opentelemetry::metrics::Counter<u64>,
    ) {
        let local = listener.local_addr();
        // All connected sockets bind to the listener's actual port so our ICE candidates (derived
        // from this port) stay reachable; `connect` then pins the egress per peer.
        let port = local.port();
        let unspecified_ip = local.ip();

        // The listener is recv-only: it catches inbound from peers/relays we haven't sent to yet.
        let _listener_recv = spawn_recv(
            Arc::new(listener),
            inbound_tx.clone(),
            io_error_counter.clone(),
            preferred_addr,
        );

        let mut pool: HashMap<(Option<IpAddr>, SocketAddr), Pooled> = HashMap::new();
        let mut pending = Vec::with_capacity(UDP_SEND_BATCH_LIMIT);
        let mut sweep = tokio::time::interval(SWEEP_INTERVAL);
        sweep.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

        loop {
            tokio::select! {
                num_batches = outbound_rx.recv_many(&mut pending, UDP_SEND_BATCH_LIMIT) => {
                    if num_batches == 0 {
                        tracing::debug!("Channel for outbound datagrams closed; exiting UDP connected-pool task");
                        return;
                    }

                    for datagram in pending.drain(..) {
                        let socket = match connected_socket(
                            &mut pool,
                            &datagram,
                            port,
                            unspecified_ip,
                            &inbound_tx,
                            &io_error_counter,
                            preferred_addr,
                        ) {
                            Ok(socket) => socket,
                            Err(e) => {
                                tracing::debug!(dst = %datagram.dst, "Failed to create connected UDP socket: {e:#}");

                                if inbound_tx.send(Err(e)).await.is_err() {
                                    return;
                                }
                                continue;
                            }
                        };

                        // `ENOBUFS` is mapped to `WouldBlock` inside `send`, so this `await` suspends
                        // (back-pressuring the outbound channel) instead of busy-retrying.
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

                            if inbound_tx.send(Err(e)).await.is_err() {
                                return;
                            }
                        }
                    }
                }
                _ = sweep.tick() => {
                    let now = Instant::now();
                    pool.retain(|_, pooled| now.duration_since(pooled.last_send) < IDLE_TIMEOUT);
                }
            }
        }
    }

    /// Looks up (or lazily creates) the connected socket for this datagram's `(src_ip, dst)`.
    fn connected_socket(
        pool: &mut HashMap<(Option<IpAddr>, SocketAddr), Pooled>,
        datagram: &DatagramOut,
        port: u16,
        unspecified_ip: IpAddr,
        inbound_tx: &mpsc::Sender<Result<DatagramSegmentIter>>,
        io_error_counter: &opentelemetry::metrics::Counter<u64>,
        preferred_addr: SocketAddr,
    ) -> Result<Arc<PerfUdpSocket>> {
        let key = (datagram.src.map(|s| s.ip()), datagram.dst);

        if let Some(pooled) = pool.get_mut(&key) {
            pooled.last_send = Instant::now();
            return Ok(pooled.socket.clone());
        }

        let bind = SocketAddr::new(key.0.unwrap_or(unspecified_ip), port);
        let mut socket = socket_factory::udp_connected(bind, datagram.dst)
            .and_then(|s| s.into_perf())
            .with_context(|| {
                format!(
                    "Failed to create connected UDP socket {bind} -> {}",
                    datagram.dst
                )
            })?;

        // These connected sockets carry the actual data plane, so they need the same large
        // send/receive buffers as the listener. Left at the OS defaults, a BDP-sized burst on a
        // high-latency path overruns the small buffer and gets dropped a whole window at a time.
        let (send_buffer_size, recv_buffer_size) = buffer_sizes();
        if let Err(e) = socket.set_buffer_sizes(send_buffer_size, recv_buffer_size) {
            tracing::warn!("Failed to set connected socket buffer sizes: {e}");
        }

        let socket = Arc::new(socket);
        let recv_task = spawn_recv(
            socket.clone(),
            inbound_tx.clone(),
            io_error_counter.clone(),
            preferred_addr,
        );

        tracing::debug!(%bind, dst = %datagram.dst, "Created connected UDP socket");

        pool.insert(
            key,
            Pooled {
                socket: socket.clone(),
                recv_task: recv_task.abort_handle(),
                last_send: Instant::now(),
            },
        );

        Ok(socket)
    }

    /// Spawns a task that reads from `socket` and forwards batches to the inbound channel.
    fn spawn_recv(
        socket: Arc<PerfUdpSocket>,
        inbound_tx: mpsc::Sender<Result<DatagramSegmentIter>>,
        io_error_counter: opentelemetry::metrics::Counter<u64>,
        preferred_addr: SocketAddr,
    ) -> tokio::task::JoinHandle<()> {
        tokio::spawn(async move {
            loop {
                let result = socket.recv_from().await;

                if let Some(io) = result
                    .as_ref()
                    .err()
                    .and_then(|e| e.any_downcast_ref::<io::Error>())
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

                if inbound_tx.send(result).await.is_err() {
                    tracing::debug!("Channel for inbound datagrams closed; exiting UDP recv task");
                    return;
                }
            }
        })
    }
}

#[derive(thiserror::Error, Debug)]
#[error("UDP socket thread stopped")]
pub struct UdpSocketThreadStopped;

#[cfg(all(test, any(target_os = "macos", target_os = "ios")))]
mod connected_tests {
    use super::*;
    use bufferpool::BufferPool;
    use bytes::BytesMut;
    use ip_packet::Ecn;
    use std::future::poll_fn;
    use std::net::UdpSocket as StdUdpSocket;

    fn datagram(dst: SocketAddr, payload: &[u8]) -> DatagramOut {
        let pool = BufferPool::<BytesMut>::new(2048, "connected-test");
        DatagramOut {
            src: None,
            dst,
            packet: pool.pull_initialised(payload),
            segment_size: payload.len(),
            ecn: Ecn::NonEct,
        }
    }

    async fn send(family: &mut ThreadedUdpSocket, datagram: DatagramOut) {
        poll_fn(|cx| family.poll_send_ready(cx)).await.unwrap();
        family.send(datagram).unwrap();
    }

    async fn recv_one(family: &mut ThreadedUdpSocket) -> (Vec<u8>, SocketAddr) {
        let mut iter = tokio::time::timeout(
            Duration::from_secs(5),
            poll_fn(|cx| family.poll_recv_from(cx)),
        )
        .await
        .expect("recv timed out")
        .expect("recv failed");
        let datagram = iter.next().expect("at least one datagram in batch");
        (datagram.packet.to_vec(), datagram.from)
    }

    /// End-to-end test of the Apple connected-socket pool: sends route through a lazily-created
    /// connected socket, replies arrive on it (with `from` overridden to the peer), and unsolicited
    /// traffic from a stranger falls through to the recv-only listener.
    #[tokio::test]
    async fn connected_pool_routes_send_and_recv_with_listener_fallback() {
        let peer = StdUdpSocket::bind("127.0.0.1:0").unwrap();
        peer.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let peer_addr = peer.local_addr().unwrap();

        let mut family = ThreadedUdpSocket::new(
            Arc::new(socket_factory::udp),
            "127.0.0.1:0".parse().unwrap(),
        )
        .unwrap();

        // Send through the connected pool; the peer learns our (connected) source address.
        send(&mut family, datagram(peer_addr, b"ping")).await;
        let mut buf = [0u8; 64];
        let (n, our_addr) = peer.recv_from(&mut buf).unwrap();
        assert_eq!(&buf[..n], b"ping");

        // Reply lands on the connected socket; `from` is overridden to the peer.
        peer.send_to(b"pong", our_addr).unwrap();
        let (payload, from) = recv_one(&mut family).await;
        assert_eq!(payload, b"pong");
        assert_eq!(
            from, peer_addr,
            "connected socket reports the peer as `from`"
        );

        // A stranger (no connected socket) hits the same port; the listener catches it.
        let stranger = StdUdpSocket::bind("127.0.0.1:0").unwrap();
        let stranger_addr = stranger.local_addr().unwrap();
        stranger.send_to(b"hello", our_addr).unwrap();
        let (payload, from) = recv_one(&mut family).await;
        assert_eq!(payload, b"hello");
        assert_eq!(
            from, stranger_addr,
            "listener reports the stranger as `from`"
        );
    }
}
