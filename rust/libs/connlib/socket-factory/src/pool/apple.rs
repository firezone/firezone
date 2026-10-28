//! The Apple [`SocketPool`]: unconnected wildcard and source sockets, plus connected flow sockets.
//!
//! Darwin gates its UDP fast path on connected sockets:
//!
//! - `sendmsg_x` only batches datagrams under a single socket lock and NECP evaluation
//!   for connected sockets (`sosend_list`); unconnected sockets degrade to an in-kernel
//!   loop with per-datagram cost.
//! - Only connected sockets participate in flow advisories: congestion surfaces as an
//!   immediate `ENOBUFS` and its clearing is signalled via write-readiness.
//!   Unconnected sockets suffer silent head-drops in the AQM instead.
//! - The route (and thus `so_pktheadroom`) is cached at connect time.
//!
//! We therefore connect a socket per `(source, destination)` pair, all bound to the same
//! local port as the unconnected catch-all socket. The kernel delivers inbound datagrams
//! with an exact 4-tuple match to the connected socket in preference to the wildcard one.
//! The catch-all remains as the wildcard receiver (ICE peer-reflexive traffic, NAT
//! rebinds) and as the fallback when connecting fails.
//!
//! Explicit sources use unconnected sockets bound to their address. Every
//! pair earns a connected flow socket when either gate proves it carries real traffic:
//!
//! - A single transmit carrying at least [`PROMOTE_BATCH_SIZE`] datagrams. Batching is
//!   what `sendmsg_x` accelerates, and a batch that large only forms when the event loop
//!   coalesces a queue's worth of same-destination datagrams in one cycle — i.e. exactly
//!   when traffic is dense enough to benefit.
//! - Sustaining [`PROMOTE_PACKETS_PER_SECOND`] across transmits. Paced senders (e.g.
//!   constant-bitrate media) may never coalesce a batch yet still need the flow
//!   advisories only a connected socket gets.
//!
//! The catch-all socket also remains the final fallback if creating a source socket fails.

use std::{
    collections::{BTreeMap, VecDeque},
    io,
    net::{IpAddr, SocketAddr},
    sync::Arc,
    task::{Context, Poll, Waker},
    time::{Duration, Instant},
};

use anyhow::Result;
use parking_lot::{Mutex, MutexGuard};
use quinn_udp::UdpSockRef;

use crate::{DatagramBatch, RecvBatch};

use super::{OwnedSocket, Socket, poll_recv_ready};

/// How many flow sockets a pool keeps at most. connlib runs one pool per address family,
/// so this is effectively the per-family cap.
///
/// Apple devices only ever run Clients, so the steady-state working set is tiny:
/// the data-bearing gateway path(s) and the relays.
const MAX_FLOW_SOCKETS: usize = 16;
const MAX_SOURCE_SOCKETS: usize = 16;

/// Datagrams a single transmit must carry for its pair to earn a flow socket.
///
/// Production batch-size percentiles inform this bound: incidental coalescence
/// (interactive traffic, control chatter) keeps p95 below ~12 datagrams per transmit,
/// while bulk transfers pin p99 at the send path's batch limit of 32. Half that limit
/// clears the incidental band and is hit within moments by anything genuinely bulk.
const PROMOTE_BATCH_SIZE: usize = 16;

/// Datagrams a pair must send within [`RATE_WINDOW`] to earn a flow socket without batching.
///
/// This promotes paced senders whose transmits never coalesce, so their congestion shows
/// up as flow advisories instead of silent AQM drops. Path probing cannot trip it: a
/// probed pair peaks at ~5 packets within a second (the initial burst) and then idles at
/// 1 packet per second, a 5x margin to this bound. Real paced traffic clears it easily —
/// a single VoIP stream alone sends 33-50 packets per second.
const PROMOTE_PACKETS_PER_SECOND: usize = 25;

/// The window over which [`PROMOTE_PACKETS_PER_SECOND`] is measured.
const RATE_WINDOW: Duration = Duration::from_secs(1);

type Key = (Option<IpAddr>, SocketAddr);

/// Unconnected wildcard and source sockets, plus connected per-pair flow sockets.
pub(crate) struct SocketPool {
    /// Unconnected socket bound to the wildcard address; receives from any peer and is the
    /// fallback for sends when connecting fails.
    wildcard: Arc<OwnedSocket>,
    /// The local address flow sockets bind to; they share the wildcard socket's port.
    local: SocketAddr,
    inner: Mutex<Inner>,
    evictions: opentelemetry::metrics::Counter<u64>,
}

struct Inner {
    flows: BTreeMap<Key, CachedSocket>,
    sources: BTreeMap<IpAddr, CachedSocket>,
    /// Send rates of pairs that have not (yet) earned a flow socket.
    rates: RateGate,
    /// A failed promotion disables new connected flows until the pool is reset.
    /// Unconnected source sockets and the wildcard remain available.
    flow_sockets_supported: bool,
    buffer_sizes: Option<(usize, usize)>,
    /// Datagrams rescued from evicted sockets before closing them.
    drained: VecDeque<DatagramBatch>,
    /// Waker of the receive task; woken when new sockets or drained datagrams appear.
    recv_waker: Option<Waker>,
    /// Counter to rotate the polling order of sockets, ensuring receive fairness.
    round_robin: usize,
}

/// A cached socket and its eviction metadata.
struct CachedSocket {
    socket: Arc<OwnedSocket>,
    created_at: Instant,
    /// Inbound activity, used to keep useful sockets during eviction.
    last_received: Mutex<Option<Instant>>,
}

impl SocketPool {
    pub(crate) fn new(wildcard: OwnedSocket) -> Self {
        trace_socket_scope(
            "wildcard_bound",
            &socket2::SockRef::from(wildcard.as_socket().inner),
            None,
            None,
            None,
        );
        let local = wildcard
            .local_addr()
            .expect("a bound socket to have a local address");

        Self {
            wildcard: Arc::new(wildcard),
            local,
            inner: Mutex::new(Inner {
                flows: BTreeMap::new(),
                sources: BTreeMap::new(),
                rates: RateGate::default(),
                flow_sockets_supported: true,
                buffer_sizes: None,
                drained: VecDeque::new(),
                recv_waker: None,
                round_robin: 0,
            }),
            evictions: otel_instruments::flow_socket_evictions(),
        }
    }

    /// Picks the socket to send a transmit of `datagrams` datagrams for `(src, dst)` on.
    ///
    /// Uses a connected flow once promoted, then a source-bound socket, then the wildcard.
    pub(crate) fn get_send_socket(
        &self,
        src: Option<IpAddr>,
        dst: SocketAddr,
        datagrams: usize,
        recv_buf_size: usize,
    ) -> Arc<OwnedSocket> {
        self.get_or_connect(src, dst, datagrams, recv_buf_size)
            .or_else(|| src.and_then(|src| self.get_or_bind_source(src, recv_buf_size)))
            .unwrap_or_else(|| self.wildcard.clone())
    }

    /// Polls all wildcard, source and flow sockets for an incoming batch, applying
    /// `try_recv` to whichever is ready first.
    ///
    /// This readiness multiplexing is the one place where async-await does not suffice: the
    /// number of sockets is variable and we must suspend on all of them at once. Everything
    /// substantial happens in `try_recv`.
    pub(crate) fn poll_recv<F>(
        &self,
        cx: &mut Context<'_>,
        mut try_recv: F,
    ) -> Poll<Result<DatagramBatch>>
    where
        F: FnMut(Socket<'_>) -> io::Result<DatagramBatch>,
    {
        let mut inner = self.lock();

        // Register the waker first: a socket created after we inspect the
        // set below must still be able to wake us.
        match &mut inner.recv_waker {
            Some(existing) if existing.will_wake(cx.waker()) => {}
            slot => *slot = Some(cx.waker().clone()),
        }

        // Datagrams rescued from evicted sockets are the oldest; yield them first.
        if let Some(batch) = inner.drained.pop_front() {
            return Poll::Ready(Ok(batch));
        }

        // Rotate the polling order by one slot per call so no socket can starve the others
        // under sustained traffic. The catch-all socket takes part as one slot among the flows.
        let position = inner.round_robin % (inner.flows.len() + inner.sources.len() + 1);
        inner.round_robin = inner.round_robin.wrapping_add(1);

        for (socket, flow) in inner.rotated_recv_order(self.wildcard.as_socket(), position) {
            if let Poll::Ready(result) = poll_recv_ready(cx, socket, &mut try_recv) {
                // Cached sockets track receive times for eviction; the wildcard is `None`.
                if let Some(flow) = flow
                    && result.is_ok()
                {
                    flow.record_received(Instant::now());
                }

                return Poll::Ready(result);
            }
        }

        Poll::Pending
    }

    pub(crate) fn set_buffer_sizes(&self, send: usize, recv: usize, port: u16) {
        self.wildcard.apply_buffer_sizes(send, recv, port);

        let mut inner = self.lock();
        inner.buffer_sizes = Some((send, recv));

        for cached in inner.flows.values().chain(inner.sources.values()) {
            cached.socket.apply_buffer_sizes(send, recv, port);
        }
    }

    /// Returns a connected flow socket once the pair passes the promotion gates.
    fn get_or_connect(
        &self,
        src: Option<IpAddr>,
        dst: SocketAddr,
        datagrams: usize,
        recv_buf_size: usize,
    ) -> Option<Arc<OwnedSocket>> {
        let key = (src, dst);
        let inner = &mut *self.lock();

        if let Some(flow) = inner.flows.get(&key) {
            return Some(flow.socket.clone());
        }

        if !inner.flow_sockets_supported {
            return None;
        }

        if datagrams < PROMOTE_BATCH_SIZE && !inner.rates.record(key, datagrams, Instant::now()) {
            return None;
        }

        match create_socket(self.local, src, Some(dst), inner.buffer_sizes) {
            Ok(socket) => {
                tracing::debug!(?src, %dst, "Connected new flow socket");

                if inner.flows.len() >= MAX_FLOW_SOCKETS
                    && let Some((src, dst)) = evict_one(
                        &mut inner.flows,
                        self.local.port(),
                        recv_buf_size,
                        &mut inner.drained,
                        &mut inner.recv_waker,
                    )
                {
                    self.evictions.add(1, &[]);
                    tracing::debug!(?src, %dst, "Evicted flow socket");
                }

                inner.rates.forget(&key);

                let socket = Arc::new(socket);
                inner.flows.insert(key, CachedSocket::new(socket.clone()));

                // The receive task only learns about the new socket on its next poll.
                if let Some(waker) = inner.recv_waker.take() {
                    waker.wake();
                }

                Some(socket)
            }
            Err(e) => {
                tracing::debug!(?src, %dst, "Disabling flow promotion; connecting failed: {e}");

                inner.flow_sockets_supported = false;

                None
            }
        }
    }

    fn get_or_bind_source(&self, src: IpAddr, recv_buf_size: usize) -> Option<Arc<OwnedSocket>> {
        let inner = &mut *self.lock();
        if let Some(source) = inner.sources.get(&src) {
            return Some(source.socket.clone());
        }

        match create_socket(self.local, Some(src), None, inner.buffer_sizes) {
            Ok(socket) => {
                if inner.sources.len() >= MAX_SOURCE_SOCKETS {
                    let _ = evict_one(
                        &mut inner.sources,
                        self.local.port(),
                        recv_buf_size,
                        &mut inner.drained,
                        &mut inner.recv_waker,
                    );
                }

                let socket = Arc::new(socket);
                inner.sources.insert(src, CachedSocket::new(socket.clone()));
                if let Some(waker) = inner.recv_waker.take() {
                    waker.wake();
                }

                Some(socket)
            }
            Err(e) => {
                tracing::debug!(%src, "Failed to bind source socket: {e}");

                None
            }
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock()
    }

    pub(crate) fn flow_socket_count(&self) -> usize {
        self.lock().flows.len()
    }
}

impl Inner {
    /// All receive sockets, rotated so that
    /// `position` starts the round.
    ///
    /// Cached sockets carry their metadata to refresh receive timestamps; the wildcard carries `None`.
    fn rotated_recv_order<'a>(
        &'a self,
        wildcard: Socket<'a>,
        position: usize,
    ) -> impl Iterator<Item = (Socket<'a>, Option<&'a CachedSocket>)> {
        std::iter::empty()
            .chain(Some((wildcard, None)))
            .chain(
                self.flows
                    .values()
                    .map(|flow| (flow.socket.as_socket(), Some(flow))),
            )
            .chain(
                self.sources
                    .values()
                    .map(|source| (source.socket.as_socket(), Some(source))),
            )
            .cycle()
            .skip(position)
            .take(self.flows.len() + self.sources.len() + 1)
    }
}

impl CachedSocket {
    fn new(socket: Arc<OwnedSocket>) -> Self {
        Self {
            socket,
            created_at: Instant::now(),
            last_received: Mutex::new(None),
        }
    }

    fn record_received(&self, now: Instant) {
        *self.last_received.lock() = Some(now);
    }
}

/// Per-pair datagram counters over a fixed [`RATE_WINDOW`].
///
/// A tumbling window rather than a sliding one: counts reset when a window expires. That
/// can at worst double the time to promotion (traffic split across two windows), which is
/// fine — the gate only needs to separate sustained senders from probing, not be precise.
#[derive(Default)]
struct RateGate {
    counters: BTreeMap<Key, RateCounter>,
}

struct RateCounter {
    window_start: Instant,
    datagrams: usize,
}

impl RateGate {
    /// Records a transmit of `datagrams` for a pair; returns whether the pair crossed
    /// [`PROMOTE_PACKETS_PER_SECOND`] within the current window and thus earned a flow socket.
    fn record(&mut self, key: Key, datagrams: usize, now: Instant) -> bool {
        // Pairs that stop sending (probed dead ends) leave counters behind; prune expired
        // ones before growing the map so it stays bounded by concurrently-active pairs.
        if self.counters.len() >= MAX_FLOW_SOCKETS * 4 && !self.counters.contains_key(&key) {
            self.counters
                .retain(|_, counter| now.duration_since(counter.window_start) < RATE_WINDOW);
        }

        let counter = self.counters.entry(key).or_insert(RateCounter {
            window_start: now,
            datagrams: 0,
        });

        if now.duration_since(counter.window_start) >= RATE_WINDOW {
            counter.window_start = now;
            counter.datagrams = 0;
        }

        counter.datagrams += datagrams;

        if counter.datagrams >= PROMOTE_PACKETS_PER_SECOND {
            self.counters.remove(&key);
            return true;
        }

        false
    }

    fn forget(&mut self, key: &Key) {
        self.counters.remove(key);
    }
}

/// Evicts and drains the least useful cached socket.
fn evict_one<K: Ord + Copy>(
    sockets: &mut BTreeMap<K, CachedSocket>,
    port: u16,
    recv_buf_size: usize,
    drained: &mut VecDeque<DatagramBatch>,
    recv_waker: &mut Option<Waker>,
) -> Option<K> {
    let key = sockets
        .iter()
        .min_by_key(|(_, cached)| eviction_rank(*cached.last_received.lock(), cached.created_at))
        .map(|(key, _)| *key)?;
    let evicted = sockets.remove(&key)?;

    drain(&evicted.socket, port, recv_buf_size, drained);
    if !drained.is_empty()
        && let Some(waker) = recv_waker.take()
    {
        waker.wake();
    }

    Some(key)
}

/// Eviction order: sockets that never received anything first (oldest first),
/// then by least-recently received.
///
/// Sockets that did receive are ranked strictly above those that never did,
/// regardless of age: a quiet-but-live established socket must survive a burst
/// of fresh, unproven sockets created during ICE connectivity checks.
fn eviction_rank(last_received: Option<Instant>, created_at: Instant) -> (bool, Instant) {
    match last_received {
        None => (false, created_at),
        Some(last_received) => (true, last_received),
    }
}

/// Reads an evicted socket dry before it is closed.
///
/// Closing a socket discards queued datagrams; drain them before another socket receives
/// subsequent traffic for its address or connected pair.
fn drain(socket: &OwnedSocket, port: u16, recv_buf_size: usize, out: &mut VecDeque<DatagramBatch>) {
    let socket = socket.as_socket();

    loop {
        let mut batch = RecvBatch::pull(recv_buf_size);

        let len = {
            let (mut io_bufs, metas) = batch.recv_slices();

            match socket.recv(&mut io_bufs, metas) {
                Ok(len) => len,
                Err(_) => break, // Typically `WouldBlock`: the socket is dry.
            }
        };

        out.push_back(DatagramBatch::new(batch.buffers, batch.metas, port, len));
    }
}

fn create_socket(
    local: SocketAddr,
    src: Option<IpAddr>,
    dst: Option<SocketAddr>,
    buffer_sizes: Option<(usize, usize)>,
) -> io::Result<OwnedSocket> {
    let bind_addr = socket2::SockAddr::from(SocketAddr::new(
        src.unwrap_or_else(|| local.ip()),
        local.port(),
    ));
    let socket = socket2::Socket::new(bind_addr.domain(), socket2::Type::DGRAM, None)?;
    trace_socket_scope("created", &socket, src, dst, None);

    if local.is_ipv6() {
        socket.set_only_v6(true)?;
        crate::prefer_stable_ipv6_source(&socket);
    }

    // Share the local port with the (unconnected) catch-all socket.
    socket.set_reuse_address(true)?;
    socket.set_reuse_port(true)?;

    socket.set_nonblocking(true)?;

    // Darwin attaches the destination-address control message when it enqueues a datagram, and
    // a connected socket captures its 4-tuple immediately, so the option must be on beforehand.
    let state = quinn_udp::UdpSocketState::new(UdpSockRef::from(&socket))?;
    // SAFETY: All versions of MacOS / iOS that we tested support these APIs.
    unsafe {
        state.set_apple_fast_path();
    }

    trace_socket_scope("before_bind", &socket, src, dst, None);
    let bind_result = socket.bind(&bind_addr);
    trace_socket_scope("after_bind", &socket, src, dst, Some(&bind_result));
    bind_result?;
    if let Some(destination) = dst {
        let connect_result = socket.connect(&socket2::SockAddr::from(destination));
        trace_socket_scope("after_connect", &socket, src, dst, Some(&connect_result));
        connect_result?;
    }

    let socket = tokio::net::UdpSocket::try_from(std::net::UdpSocket::from(socket))?;
    let socket = OwnedSocket::new(socket, state, dst.is_some());

    if let Some((send, recv)) = buffer_sizes {
        socket.apply_buffer_sizes(send, recv, local.port());
    }

    Ok(socket)
}

fn trace_socket_scope(
    stage: &str,
    socket: &socket2::Socket,
    src: Option<IpAddr>,
    dst: Option<SocketAddr>,
    operation: Option<&io::Result<()>>,
) {
    tracing::debug!(
        stage,
        ?src,
        ?dst,
        bound_if_v4 = ?socket.device_index_v4(),
        bound_if_v6 = ?socket.device_index_v6(),
        local_addr = ?socket.local_addr().map(|addr| addr.as_socket()),
        peer_addr = ?socket.peer_addr().map(|addr| addr.as_socket()),
        operation_ok = ?operation.map(|result| result.is_ok()),
        raw_errno = ?operation.and_then(|result| result.as_ref().err()).and_then(io::Error::raw_os_error),
        "Apple UDP socket scope snapshot"
    );
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use super::*;

    #[tokio::test]
    async fn source_sockets_keep_the_source_address_and_port_after_promotion() {
        for (local, source) in [
            ("0.0.0.0:0", IpAddr::V4(Ipv4Addr::LOCALHOST)),
            ("[::]:0", IpAddr::V6(std::net::Ipv6Addr::LOCALHOST)),
        ] {
            let socket = crate::udp(local.parse().unwrap())
                .unwrap()
                .into_perf()
                .unwrap();
            let destination = SocketAddr::new(source, 9);

            for datagrams in [1, PROMOTE_BATCH_SIZE] {
                let selected =
                    socket
                        .pool
                        .get_send_socket(Some(source), destination, datagrams, 1500);
                let borrowed = selected.as_socket();
                assert_eq!(borrowed.connected, datagrams == PROMOTE_BATCH_SIZE);
                assert_eq!(
                    selected.local_addr().unwrap(),
                    SocketAddr::new(source, socket.pool.local.port())
                );
            }
        }
    }

    #[test]
    fn never_received_sockets_are_evicted_before_received_ones() {
        let earlier = Instant::now();
        let later = earlier + Duration::from_secs(60);

        // A fresh, unproven socket ranks below one that received long ago.
        assert!(eviction_rank(None, later) < eviction_rank(Some(earlier), earlier));
    }

    #[test]
    fn oldest_never_received_socket_is_evicted_first() {
        let earlier = Instant::now();
        let later = earlier + Duration::from_secs(60);

        assert!(eviction_rank(None, earlier) < eviction_rank(None, later));
    }

    #[test]
    fn least_recently_received_socket_is_evicted_first() {
        let earlier = Instant::now();
        let later = earlier + Duration::from_secs(60);

        assert!(eviction_rank(Some(earlier), earlier) < eviction_rank(Some(later), earlier));
    }

    const KEY: Key = (None, SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 1234));

    #[test]
    fn paced_sender_promotes_within_a_window() {
        let mut gate = RateGate::default();
        let start = Instant::now();

        // 20ms pacing, one datagram per transmit: 50 packets/s.
        let promoted = (0..PROMOTE_PACKETS_PER_SECOND)
            .any(|i| gate.record(KEY, 1, start + Duration::from_millis(20 * i as u64)));

        assert!(promoted);
    }

    #[test]
    fn probe_cadence_never_promotes() {
        let mut gate = RateGate::default();
        let start = Instant::now();

        // The initial probe burst: 4 packets within the first second ...
        for gap in [0, 200, 500, 1000] {
            assert!(!gate.record(KEY, 1, start + Duration::from_millis(gap)));
        }

        // ... then one probe per second, forever.
        for i in 2..120 {
            assert!(!gate.record(KEY, 1, start + Duration::from_secs(i)));
        }
    }

    #[test]
    fn expired_window_forgets_earlier_transmits() {
        let mut gate = RateGate::default();
        let start = Instant::now();

        for _ in 0..PROMOTE_PACKETS_PER_SECOND - 1 {
            assert!(!gate.record(KEY, 1, start));
        }

        // Just under the threshold again, but in a fresh window: no promotion.
        let later = start + RATE_WINDOW;
        for _ in 0..PROMOTE_PACKETS_PER_SECOND - 1 {
            assert!(!gate.record(KEY, 1, later));
        }
    }

    #[test]
    fn stale_counters_are_pruned() {
        let mut gate = RateGate::default();
        let start = Instant::now();

        for port in 0..MAX_FLOW_SOCKETS as u16 * 4 {
            let key = (None, SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port));
            gate.record(key, 1, start);
        }

        gate.record(KEY, 1, start + RATE_WINDOW);

        assert_eq!(gate.counters.len(), 1);
    }
}
