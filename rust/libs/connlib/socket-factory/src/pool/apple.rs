//! The Apple [`SocketPool`]: an unconnected catch-all socket plus a cache of connected "flow"
//! sockets.
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
    sync::Arc,
    task::{Context, Poll, Waker},
    time::Instant,
};

use anyhow::Result;
use parking_lot::{Mutex, MutexGuard};
use quinn_udp::UdpSockRef;

use crate::{DatagramSegmentIter, RecvBatch, RecvBuffers};

use super::{OwnedSocket, Socket, poll_recv_ready};

/// How many flow sockets a pool keeps at most. connlib runs one pool per address family,
/// so this is effectively the per-family cap.
///
/// Apple devices only ever run Clients, so the steady-state working set is tiny:
/// the connected gateway(s) and possibly a relay. The cap mainly bounds the burst
/// of short-lived sockets during ICE connectivity checks.
const MAX_FLOW_SOCKETS: usize = if cfg!(target_os = "ios") { 8 } else { 16 };

type Key = (Option<IpAddr>, SocketAddr);

/// The unconnected catch-all socket plus a cache of connected flow sockets, keyed by
/// `(source IP, destination)`.
pub(crate) struct SocketPool {
    /// Unconnected socket bound to the wildcard address; receives from any peer and is the
    /// fallback for sends when connecting fails.
    wildcard: Arc<OwnedSocket>,
    /// The local address flow sockets bind to; they share the wildcard socket's port.
    local: SocketAddr,
    inner: Mutex<Inner>,
}

struct Inner {
    flows: BTreeMap<Key, Flow>,
    /// Latched off the first time connecting a flow socket fails.
    ///
    /// A failure means the environment (e.g. the iOS Network Extension sandbox) doesn't permit
    /// the `SO_REUSEPORT`-bind + `connect` we rely on. That is a property of the environment, not
    /// the destination, so we stop connecting *new* flow sockets - new destinations fall back to
    /// the catch-all socket - and avoid re-running the failing syscalls on the send path. Any flow
    /// sockets already connected keep working. Re-binding the sockets on a network change builds a
    /// fresh [`SocketPool`], giving connecting another chance.
    flow_sockets_supported: bool,
    buffer_sizes: Option<(usize, usize)>,
    /// Datagrams rescued from an evicted socket's receive buffer just before closing it.
    drained: VecDeque<DatagramSegmentIter>,
    /// Waker of the receive task; woken when new sockets or drained datagrams appear.
    recv_waker: Option<Waker>,
    /// Counter to rotate the polling order of sockets, ensuring receive fairness.
    round_robin: usize,
}

/// A connected flow socket plus the metadata the cache needs to evict it.
struct Flow {
    socket: Arc<OwnedSocket>,
    created_at: Instant,
    /// When we last read a datagram off this socket.
    ///
    /// Inbound on the exact 4-tuple is the only signal that a path actually works:
    /// sends are self-generated and keep flowing to dead destinations too.
    ///
    /// Interior-mutable so the receive path can update it while iterating the cache.
    last_received: Mutex<Option<Instant>>,
}

impl SocketPool {
    pub(crate) fn new(wildcard: OwnedSocket) -> Self {
        let local = wildcard
            .local_addr()
            .expect("a bound socket to have a local address");

        Self {
            wildcard: Arc::new(wildcard),
            local,
            inner: Mutex::new(Inner {
                flows: BTreeMap::new(),
                flow_sockets_supported: true,
                buffer_sizes: None,
                drained: VecDeque::new(),
                recv_waker: None,
                round_robin: 0,
            }),
        }
    }

    /// Picks the socket to send a datagram for `(src, dst)` on.
    ///
    /// Connects (or reuses) a flow socket; on failure it falls back to the catch-all socket.
    pub(crate) fn get_send_socket(
        &self,
        src: Option<IpAddr>,
        dst: SocketAddr,
        recv_buffers: &RecvBuffers,
    ) -> Arc<OwnedSocket> {
        self.get_or_connect(src, dst, recv_buffers)
            .unwrap_or_else(|| self.wildcard.clone())
    }

    /// Polls the catch-all socket and all flow sockets for an incoming batch, applying
    /// `try_recv` to whichever is ready first.
    ///
    /// This readiness multiplexing is the one place where async-await does not suffice: the
    /// number of sockets is variable and we must suspend on all of them at once. Everything
    /// substantial happens in `try_recv`.
    pub(crate) fn poll_recv<F>(
        &self,
        cx: &mut Context<'_>,
        mut try_recv: F,
    ) -> Poll<Result<DatagramSegmentIter>>
    where
        F: FnMut(Socket<'_>) -> io::Result<DatagramSegmentIter>,
    {
        let mut inner = self.lock();

        // Register the waker first: a flow socket connected after we inspect the
        // set below must still be able to wake us.
        match &mut inner.recv_waker {
            Some(existing) if existing.will_wake(cx.waker()) => {}
            slot => *slot = Some(cx.waker().clone()),
        }

        // Datagrams rescued from an evicted flow socket are the oldest; yield them first.
        if let Some(iter) = inner.drained.pop_front() {
            return Poll::Ready(Ok(iter));
        }

        // Rotate the polling order by one slot per call so no socket can starve the others
        // under sustained traffic. The catch-all socket takes part as one slot among the flows.
        let position = inner.round_robin % (inner.flows.len() + 1);
        inner.round_robin = inner.round_robin.wrapping_add(1);

        for (socket, flow) in inner.rotated_recv_order(self.wildcard.as_socket(), position) {
            if let Poll::Ready(result) = poll_recv_ready(cx, socket, &mut try_recv) {
                // Only flow sockets track a last-received time (for eviction); the wildcard is `None`.
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

        for flow in inner.flows.values() {
            flow.socket.apply_buffer_sizes(send, recv, port);
        }
    }

    /// Returns the flow socket for the given `(src, dst)` pair, connecting a new one if needed.
    ///
    /// Returns `None` if connecting fails (or has failed before); see `Inner::flow_sockets_supported`.
    fn get_or_connect(
        &self,
        src: Option<IpAddr>,
        dst: SocketAddr,
        recv_buffers: &RecvBuffers,
    ) -> Option<Arc<OwnedSocket>> {
        let key = (src, dst);
        let mut inner = self.lock();

        if let Some(flow) = inner.flows.get(&key) {
            return Some(flow.socket.clone());
        }

        if !inner.flow_sockets_supported {
            return None;
        }

        if inner.flows.len() >= MAX_FLOW_SOCKETS {
            evict_one(&mut inner, self.local.port(), recv_buffers);
        }

        match connect(self.local, src, dst, inner.buffer_sizes) {
            Ok(socket) => {
                tracing::debug!(?src, %dst, "Connected new flow socket");

                let socket = Arc::new(socket);
                inner.flows.insert(
                    key,
                    Flow {
                        socket: socket.clone(),
                        created_at: Instant::now(),
                        last_received: Mutex::new(None),
                    },
                );

                // The receive task only learns about the new socket on its next poll.
                if let Some(waker) = inner.recv_waker.take() {
                    waker.wake();
                }

                Some(socket)
            }
            Err(e) => {
                tracing::debug!(?src, %dst, "Disabling flow sockets; connecting failed: {e}");

                inner.flow_sockets_supported = false;

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
    /// All receive sockets - the catch-all `wildcard` plus the flow sockets - rotated so that
    /// `position` starts the round.
    ///
    /// Each flow socket carries its [`Flow`] so the receive path can refresh its last-received
    /// timestamp; the wildcard carries `None`.
    fn rotated_recv_order<'a>(
        &'a self,
        wildcard: Socket<'a>,
        position: usize,
    ) -> impl Iterator<Item = (Socket<'a>, Option<&'a Flow>)> {
        std::iter::empty()
            .chain(Some((wildcard, None)))
            .chain(
                self.flows
                    .values()
                    .map(|flow| (flow.socket.as_socket(), Some(flow))),
            )
            .cycle()
            .skip(position)
            .take(self.flows.len() + 1)
    }
}

impl Flow {
    fn record_received(&self, now: Instant) {
        *self.last_received.lock() = Some(now);
    }
}

/// Evicts the flow socket that is least likely to still be useful.
fn evict_one(inner: &mut Inner, port: u16, recv_buffers: &RecvBuffers) {
    let Some(key) = inner
        .flows
        .iter()
        .min_by_key(|(_, flow)| {
            let last_received = *flow.last_received.lock();

            eviction_rank(last_received, flow.created_at)
        })
        .map(|(key, _)| *key)
    else {
        return;
    };

    let Some(victim) = inner.flows.remove(&key) else {
        return;
    };

    drain(&victim, port, recv_buffers, &mut inner.drained);

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
    victim: &Flow,
    port: u16,
    recv_buffers: &RecvBuffers,
    out: &mut VecDeque<DatagramSegmentIter>,
) {
    let socket = victim.socket.as_socket();

    loop {
        let RecvBatch {
            mut buffers,
            mut metas,
        } = recv_buffers.pull_batch();

        let len = {
            let mut io_bufs = buffers
                .iter_mut()
                .map(|b| IoSliceMut::new(b))
                .collect::<smallvec::SmallVec<[_; quinn_udp::BATCH_SIZE]>>();

            match socket.recv(&mut io_bufs, &mut metas) {
                Ok(len) => len,
                Err(_) => break, // Typically `WouldBlock`: the socket is dry.
            }
        };

        out.push_back(DatagramSegmentIter::new(buffers, metas, port, len));
    }
}

fn connect(
    local: SocketAddr,
    src: Option<IpAddr>,
    dst: SocketAddr,
    buffer_sizes: Option<(usize, usize)>,
) -> io::Result<OwnedSocket> {
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

    let socket = OwnedSocket::new(socket, state, true);

    if let Some((send, recv)) = buffer_sizes {
        socket.apply_buffer_sizes(send, recv, local.port());
    }

    Ok(socket)
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

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
