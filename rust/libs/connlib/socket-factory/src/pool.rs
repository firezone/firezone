//! The [`SocketPool`]: the set of UDP sockets [`PerfUdpSocket`](crate::PerfUdpSocket) sends and
//! receives on, plus the small vocabulary the send and receive paths share.
//!
//! There are two implementations behind a single platform-selected `SocketPool` alias:
//!
//! - `apple`: wildcard and source-bound unconnected sockets, plus connected flow sockets
//!   that unlock Darwin's UDP fast path and flow advisories.
//! - `fallback`: just the catch-all socket, for every other platform.

#[cfg(apple)]
mod apple;
#[cfg(not(apple))]
mod fallback;

#[cfg(apple)]
pub(crate) use apple::SocketPool;
#[cfg(not(apple))]
pub(crate) use fallback::SocketPool;

use std::{
    io::{self, IoSliceMut},
    task::{Context, Poll},
};

use anyhow::{Context as _, Result};
use quinn_udp::UdpSockRef;

use crate::{DatagramBatch, apply_buffer_size};

/// A borrowed handle to a UDP socket and its quinn state - the currency the send and receive
/// paths operate on, regardless of which [`SocketPool`] member it came from.
#[derive(Clone, Copy)]
pub(crate) struct Socket<'a> {
    pub(crate) inner: &'a tokio::net::UdpSocket,
    pub(crate) state: &'a quinn_udp::UdpSocketState,
    /// Whether the socket is `connect`ed to a fixed peer and thus takes Darwin's fast path.
    pub(crate) connected: bool,
}

impl Socket<'_> {
    /// Receives a batch of datagrams into `bufs`, without blocking.
    pub(crate) fn recv(
        &self,
        bufs: &mut [IoSliceMut<'_>],
        meta: &mut [quinn_udp::RecvMeta],
    ) -> io::Result<usize> {
        self.state.recv(UdpSockRef::from(self.inner), bufs, meta)
    }

    /// Opts the socket out of URO.
    #[cfg(windows)]
    pub(crate) fn disable_gro(&self) {
        if let Err(e) = self.state.set_gro(UdpSockRef::from(self.inner), false) {
            tracing::warn!("Failed to disable URO: {e}");
        }
    }
}

/// A UDP socket and its quinn state, owned. The unit a [`SocketPool`] is made of.
pub(crate) struct OwnedSocket {
    socket: tokio::net::UdpSocket,
    state: quinn_udp::UdpSocketState,
    connected: bool,
}

impl OwnedSocket {
    pub(crate) fn new(
        socket: tokio::net::UdpSocket,
        state: quinn_udp::UdpSocketState,
        connected: bool,
    ) -> Self {
        #[cfg(windows)]
        enable_gro(&socket, &state);

        Self {
            socket,
            state,
            connected,
        }
    }

    pub(crate) fn as_socket(&self) -> Socket<'_> {
        Socket {
            inner: &self.socket,
            state: &self.state,
            connected: self.connected,
        }
    }

    #[cfg(apple)]
    pub(crate) fn local_addr(&self) -> io::Result<std::net::SocketAddr> {
        self.socket.local_addr()
    }

    /// Applies the requested send and recv buffer sizes, best-effort.
    pub(crate) fn apply_buffer_sizes(&self, send: usize, recv: usize, port: u16) {
        let socket = socket2::SockRef::from(&self.socket);

        let (send_forced, recv_forced) = cfg_select! {
            any(target_os = "linux", target_os = "android") => {(
                force_buffer_size(&socket, libc::SO_SNDBUFFORCE, send),
                force_buffer_size(&socket, libc::SO_RCVBUFFORCE, recv),
            )}
            _ => { (false, false) }
        };

        // Apply each direction independently: failing to set one buffer size must not prevent the other from being applied.
        if !send_forced
            && let Err(e) = apply_buffer_size(send, |size| socket.set_send_buffer_size(size))
        {
            tracing::warn!(requested_send_buffer_size = %send, "Failed to set send buffer size: {e}");
        }

        if !recv_forced
            && let Err(e) = apply_buffer_size(recv, |size| socket.set_recv_buffer_size(size))
        {
            tracing::warn!(requested_recv_buffer_size = %recv, "Failed to set recv buffer size: {e}");
        }

        let send_buffer_size = socket.send_buffer_size().unwrap_or_default();
        let recv_buffer_size = socket.recv_buffer_size().unwrap_or_default();

        tracing::debug!(requested_send_buffer_size = %send, %send_buffer_size, requested_recv_buffer_size = %recv, %recv_buffer_size, %port, "UDP socket buffer sizes");
    }
}

/// Sets a buffer size past `net.core.{w,r}mem_max`, which requires `CAP_NET_ADMIN`.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn force_buffer_size(socket: &socket2::SockRef<'_>, option: libc::c_int, size: usize) -> bool {
    use std::os::fd::AsRawFd as _;

    let value = libc::c_int::try_from(size).unwrap_or(libc::c_int::MAX);

    // SAFETY: `value` outlives the call and the option length matches its type.
    let ret = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            option,
            &value as *const libc::c_int as *const libc::c_void,
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        )
    };

    if ret != 0 {
        let error = io::Error::last_os_error();

        tracing::debug!(%error, %option, requested_size = %size, "Failed to force socket buffer size");

        return false;
    }

    true
}

/// Opts a socket into URO unless broken coalescing has been observed (see [`crate::uro`]).
#[cfg(windows)]
fn enable_gro(socket: &tokio::net::UdpSocket, state: &quinn_udp::UdpSocketState) {
    if crate::uro::is_broken() {
        return;
    }

    if let Err(e) = state.set_gro(UdpSockRef::from(socket), true) {
        tracing::debug!("Failed to enable URO: {e}");

        return;
    }

    tracing::debug!("Enabled URO");
}

/// Polls a single socket for readiness and, when ready, tries to receive a batch.
///
/// Shared by every [`SocketPool`] implementation.
pub(crate) fn poll_recv_ready<F>(
    cx: &mut Context<'_>,
    socket: Socket<'_>,
    try_recv: &mut F,
) -> Poll<Result<DatagramBatch>>
where
    F: FnMut(Socket<'_>) -> io::Result<DatagramBatch>,
{
    loop {
        match socket.inner.poll_recv_ready(cx) {
            Poll::Pending => return Poll::Pending,
            Poll::Ready(Err(e)) => {
                return Poll::Ready(Err(e).context("Failed to wait for socket to become readable"));
            }
            Poll::Ready(Ok(())) => {}
        }

        match try_recv(socket) {
            // The readiness was stale; `try_io` cleared it, so the next poll above suspends.
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue,
            result => return Poll::Ready(result.context("Failed to read from socket")),
        }
    }
}
