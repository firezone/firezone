//! Connected "flow" sockets for Apple platforms.
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
//! We therefore connect a socket per `(source, destination)` pair on first send, all bound
//! to the same local port as the unconnected catch-all socket. The kernel delivers inbound
//! datagrams with an exact 4-tuple match to the connected socket in preference to the
//! wildcard one. The catch-all remains as the wildcard receiver (ICE peer-reflexive
//! traffic, NAT rebinds) and as the fallback when connecting fails.

use std::{
    collections::{BTreeMap, VecDeque},
    io::{self, IoSliceMut},
    net::{IpAddr, SocketAddr},
    sync::{Arc, Mutex, MutexGuard},
    task::Waker,
    time::{Duration, Instant},
};

use bufferpool::BufferPool;
use quinn_udp::UdpSockRef;

use crate::DatagramSegmentIter;

/// How many flow sockets we maintain at most, per address family.
///
/// Apple devices only ever run Clients, so the steady-state working set is tiny:
/// the connected gateway(s) and possibly a relay. The cap mainly bounds the burst
/// of short-lived sockets during ICE connectivity checks.
const MAX_FLOW_SOCKETS: usize = if cfg!(target_os = "ios") { 8 } else { 16 };

/// How long we wait until we retry connecting a flow socket for a destination after a failure.
const CONNECT_COOLDOWN: Duration = Duration::from_secs(60);

type Key = (Option<IpAddr>, SocketAddr);

/// A cache of connected UDP sockets, keyed by `(source IP, destination)`.
pub(crate) struct FlowSockets {
    /// The local address of the catch-all socket; flow sockets share its port.
    local: SocketAddr,
    inner: Mutex<Inner>,
}

struct Inner {
    sockets: BTreeMap<Key, Arc<FlowSocket>>,
    /// Destinations we recently failed to connect to; sends fall back to the catch-all socket.
    cooldowns: BTreeMap<Key, Instant>,
    buffer_sizes: Option<(usize, usize)>,
    /// Datagrams rescued from an evicted socket's receive buffer just before closing it.
    drained: VecDeque<DatagramSegmentIter>,
    /// Waker of the receive task; woken when new sockets or drained datagrams appear.
    recv_waker: Option<Waker>,
    /// Counter to rotate the polling order of sockets, ensuring receive fairness.
    round_robin: usize,
}

pub(crate) struct FlowSocket {
    socket: tokio::net::UdpSocket,
    state: quinn_udp::UdpSocketState,
    created_at: Instant,
    /// When we last read a datagram off this socket.
    ///
    /// Inbound on the exact 4-tuple is the only signal that a path actually works:
    /// sends are self-generated and keep flowing to dead destinations too.
    last_received: Mutex<Option<Instant>>,
}

impl FlowSockets {
    pub(crate) fn new(local: SocketAddr) -> Self {
        Self {
            local,
            inner: Mutex::new(Inner {
                sockets: BTreeMap::new(),
                cooldowns: BTreeMap::new(),
                buffer_sizes: None,
                drained: VecDeque::new(),
                recv_waker: None,
                round_robin: 0,
            }),
        }
    }

    /// Returns the flow socket for the given `(src, dst)` pair, connecting a new one if needed.
    ///
    /// Returns `None` if connecting fails or recently failed;
    /// the caller must fall back to the catch-all socket.
    pub(crate) fn get_or_connect(
        &self,
        src: Option<IpAddr>,
        dst: SocketAddr,
        pool: &BufferPool<Vec<u8>>,
    ) -> Option<Arc<FlowSocket>> {
        let key = (src, dst);
        let mut inner = self.lock();

        if let Some(socket) = inner.sockets.get(&key) {
            return Some(socket.clone());
        }

        let now = Instant::now();

        if let Some(failed_at) = inner.cooldowns.get(&key) {
            if now.duration_since(*failed_at) < CONNECT_COOLDOWN {
                return None;
            }

            inner.cooldowns.remove(&key);
        }

        if inner.sockets.len() >= MAX_FLOW_SOCKETS {
            evict_one(&mut inner, self.local.port(), pool);
        }

        match connect(self.local, src, dst, inner.buffer_sizes) {
            Ok(socket) => {
                tracing::debug!(?src, %dst, "Connected new flow socket");

                let socket = Arc::new(socket);
                inner.sockets.insert(key, socket.clone());

                // The receive task only learns about the new socket on its next poll.
                if let Some(waker) = inner.recv_waker.take() {
                    waker.wake();
                }

                Some(socket)
            }
            Err(e) => {
                tracing::debug!(?src, %dst, "Failed to connect flow socket: {e}");

                inner
                    .cooldowns
                    .retain(|_, failed_at| now.duration_since(*failed_at) < CONNECT_COOLDOWN);
                inner.cooldowns.insert(key, now);

                None
            }
        }
    }

    /// Pops a batch of datagrams rescued from an evicted socket, if any.
    pub(crate) fn pop_drained(&self) -> Option<DatagramSegmentIter> {
        self.lock().drained.pop_front()
    }

    /// The order in which the sockets should be polled for receiving.
    ///
    /// The order rotates by one position per call - with the catch-all socket occupying
    /// a virtual slot - so that no socket can starve the others under sustained traffic.
    pub(crate) fn poll_order(&self) -> PollOrder<'_> {
        let mut inner = self.lock();

        let position = inner.round_robin % (inner.sockets.len() + 1);
        inner.round_robin = inner.round_robin.wrapping_add(1);

        PollOrder { inner, position }
    }

    /// Registers the receive task's waker.
    ///
    /// Must be called _before_ inspecting the polling order so that a socket connected
    /// after the snapshot still wakes the receive task.
    pub(crate) fn register_recv_waker(&self, waker: &Waker) {
        let mut inner = self.lock();

        match &mut inner.recv_waker {
            Some(existing) if existing.will_wake(waker) => {}
            slot => *slot = Some(waker.clone()),
        }
    }

    pub(crate) fn set_buffer_sizes(&self, send: usize, recv: usize) {
        let mut inner = self.lock();

        inner.buffer_sizes = Some((send, recv));

        for socket in inner.sockets.values() {
            apply_buffer_sizes(&socket.socket, send, recv);
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().expect("mutex should not be poisoned")
    }
}

impl FlowSocket {
    pub(crate) fn socket(&self) -> &tokio::net::UdpSocket {
        &self.socket
    }

    pub(crate) fn state(&self) -> &quinn_udp::UdpSocketState {
        &self.state
    }

    pub(crate) fn record_received(&self, now: Instant) {
        *self
            .last_received
            .lock()
            .expect("mutex should not be poisoned") = Some(now);
    }
}

/// A view of all flow sockets, fixing the order in which to poll them for this round.
///
/// Holds the cache locked; this is fine because polling sockets for readiness never blocks
/// and the receive task is done with the view before it suspends.
pub(crate) struct PollOrder<'a> {
    inner: MutexGuard<'a, Inner>,
    /// This round's slot of the catch-all socket; the flow sockets fill the remaining slots.
    position: usize,
}

impl PollOrder<'_> {
    /// Whether the catch-all socket should be polled before the flow sockets this round.
    pub(crate) fn catch_all_first(&self) -> bool {
        self.position == 0
    }

    /// The flow sockets, rotated for this round.
    pub(crate) fn sockets(&self) -> impl Iterator<Item = &Arc<FlowSocket>> {
        let num_sockets = self.inner.sockets.len();
        let offset = self.position.saturating_sub(1);

        self.inner
            .sockets
            .values()
            .cycle()
            .skip(offset)
            .take(num_sockets)
    }
}

/// Evicts the flow socket that is least likely to still be useful.
fn evict_one(inner: &mut Inner, port: u16, pool: &BufferPool<Vec<u8>>) {
    let Some(key) = inner
        .sockets
        .iter()
        .min_by_key(|(_, socket)| {
            let last_received = *socket
                .last_received
                .lock()
                .expect("mutex should not be poisoned");

            eviction_rank(last_received, socket.created_at)
        })
        .map(|(key, _)| *key)
    else {
        return;
    };

    let Some(victim) = inner.sockets.remove(&key) else {
        return;
    };

    drain(&victim, port, pool, &mut inner.drained);

    if !inner.drained.is_empty()
        && let Some(waker) = inner.recv_waker.take()
    {
        waker.wake();
    }

    tracing::debug!(src = ?key.0, dst = %key.1, "Evicted flow socket");
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
/// A connected socket captures inbound for its 4-tuple; whatever is already queued would be
/// discarded by the kernel on close. Packets arriving after the close are delivered to the
/// catch-all socket instead.
fn drain(
    victim: &FlowSocket,
    port: u16,
    pool: &BufferPool<Vec<u8>>,
    out: &mut VecDeque<DatagramSegmentIter>,
) {
    loop {
        let mut bufs = std::array::from_fn(|_| pool.pull());
        let mut metas = std::array::from_fn(|_| quinn_udp::RecvMeta::default());

        let len = {
            let mut io_bufs = bufs.each_mut().map(|b| IoSliceMut::new(b));

            match victim
                .state
                .recv(UdpSockRef::from(&victim.socket), &mut io_bufs, &mut metas)
            {
                Ok(len) => len,
                Err(_) => break, // Typically `WouldBlock`: the socket is dry.
            }
        };

        out.push_back(DatagramSegmentIter::new(bufs, metas, port, len));
    }
}

fn connect(
    local: SocketAddr,
    src: Option<IpAddr>,
    dst: SocketAddr,
    buffer_sizes: Option<(usize, usize)>,
) -> io::Result<FlowSocket> {
    let bind_addr = socket2::SockAddr::from(SocketAddr::new(
        src.unwrap_or_else(|| local.ip()),
        local.port(),
    ));
    let dst_addr = socket2::SockAddr::from(dst);

    let socket = socket2::Socket::new(dst_addr.domain(), socket2::Type::DGRAM, None)?;

    if dst.is_ipv6() {
        socket.set_only_v6(true)?;
    }

    // Share the local port with the (unconnected) catch-all socket.
    socket.set_reuse_address(true)?;
    socket.set_reuse_port(true)?;

    socket.set_nonblocking(true)?;
    socket.bind(&bind_addr)?;
    socket.connect(&dst_addr)?;

    let socket = tokio::net::UdpSocket::try_from(std::net::UdpSocket::from(socket))?;

    let state = quinn_udp::UdpSocketState::new(UdpSockRef::from(&socket))?;
    // SAFETY: All versions of MacOS / iOS that we tested support these APIs.
    unsafe {
        state.set_apple_fast_path();
    }

    if let Some((send, recv)) = buffer_sizes {
        apply_buffer_sizes(&socket, send, recv);
    }

    Ok(FlowSocket {
        socket,
        state,
        created_at: Instant::now(),
        last_received: Mutex::new(None),
    })
}

fn apply_buffer_sizes(socket: &tokio::net::UdpSocket, send: usize, recv: usize) {
    let socket = socket2::SockRef::from(socket);

    if let Err(e) = crate::apply_buffer_size(send, |size| socket.set_send_buffer_size(size)) {
        tracing::debug!("Failed to set send buffer size on flow socket: {e}");
    }

    if let Err(e) = crate::apply_buffer_size(recv, |size| socket.set_recv_buffer_size(size)) {
        tracing::debug!("Failed to set recv buffer size on flow socket: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
