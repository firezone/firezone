use anyhow::{Context as _, Result};
use bufferpool::{Buffer, BufferPool, VecBuf};
use bytes::{Buf as _, BytesMut};
use gat_lending_iterator::LendingIterator;
use ip_packet::{Ecn, Ipv4Header, Ipv6Header, UdpHeader};
use opentelemetry::KeyValue;
use quinn_udp::{EcnCodepoint, Transmit, UdpSockRef};
use smallvec::SmallVec;
use std::io;
use std::io::IoSliceMut;
use std::ops::Deref;
use std::{
    net::{IpAddr, SocketAddr},
    task::{Context, Poll},
};

use std::any::Any;
use std::pin::Pin;
use tokio::io::Interest;

mod pool;

use pool::{OwnedSocket, Socket, SocketPool};

pub trait SocketFactory<S>: Send + Sync + 'static {
    fn bind(&self, local: SocketAddr) -> io::Result<S>;
    fn reset(&self);
}

/// On Apple platforms, UDP sockets never buffer data in the send buffer: datagrams are
/// handed straight to the interface and `SO_SNDBUF` only acts as a cap on the maximum
/// datagram size. A large send buffer is therefore pointless (and cannot cause
/// bufferbloat either); 64 KiB comfortably covers the largest datagram we ever send.
#[cfg(apple)]
pub const SEND_BUFFER_SIZE: usize = 64 * 1024;
#[cfg(not(apple))]
pub const SEND_BUFFER_SIZE: usize = 16 * ONE_MB;
pub const RECV_BUFFER_SIZE: usize = 128 * ONE_MB;
const ONE_MB: usize = 1024 * 1024;

/// How many times we at most try to re-send a packet if we encounter ENOBUFS on MacOS / iOS or 10055 on Windows.
#[cfg(any(apple, target_os = "windows"))]
const MAX_ENOBUFS_RETRIES: u32 = 24;

/// Upper bound (as a power of two) for how many times we busy-spin between send retries.
///
/// `2^6 = 64` iterations of [`std::hint::spin_loop`] stay well below a microsecond.
const SPIN_LIMIT: u32 = 6;

/// The Windows equivalent of ENOBUFS.
///
/// "An operation on a socket could not be performed because the system lacked sufficient buffer space or because a queue was full. (os error 10055)"
#[cfg(target_os = "windows")]
const WINDOWS_ENOBUFS: i32 = 10055;

impl<F, S> SocketFactory<S> for F
where
    F: Fn(SocketAddr) -> io::Result<S> + Send + Sync + 'static,
{
    fn bind(&self, local: SocketAddr) -> io::Result<S> {
        (self)(local)
    }

    fn reset(&self) {}
}

pub fn tcp(addr: SocketAddr) -> io::Result<TcpSocket> {
    let socket = match addr {
        SocketAddr::V4(_) => tokio::net::TcpSocket::new_v4()?,
        SocketAddr::V6(_) => tokio::net::TcpSocket::new_v6()?,
    };

    socket.set_nodelay(true)?;

    Ok(TcpSocket {
        inner: socket,
        backpack: None,
    })
}

pub fn udp(std_addr: SocketAddr) -> io::Result<UdpSocket> {
    let addr = socket2::SockAddr::from(std_addr);
    let socket = socket2::Socket::new(addr.domain(), socket2::Type::DGRAM, None)?;

    // Note: for AF_INET sockets IPV6_V6ONLY is not a valid flag
    if addr.is_ipv6() {
        socket.set_only_v6(true)?;
        prefer_stable_ipv6_source(&socket);
    }

    socket.set_nonblocking(true)?;

    // On Apple, connected flow sockets share the catch-all socket's local port (see `pool::apple`).
    // Darwin only lets sockets share a port if every one of them - including the one bound first -
    // opts into `SO_REUSEPORT`, so set it (and `SO_REUSEADDR`, to match the flow sockets) before
    // binding. Without this the first flow `bind()` fails with `EADDRINUSE` and the fast path
    // latches off.
    #[cfg(apple)]
    {
        socket.set_reuse_address(true)?;
        socket.set_reuse_port(true)?;
    }

    socket.bind(&addr)?;

    let socket = std::net::UdpSocket::from(socket);
    let socket = tokio::net::UdpSocket::try_from(socket)?;
    let socket = UdpSocket::new(socket)?;

    Ok(socket)
}

/// The socket option to prefer a stable IPv6 source address, with the value that selects it.
///
/// On Apple, `IPV6_PREFER_TEMPADDR` (from xnu's `netinet6/in6.h`, not exposed by `libc`)
/// overrides the system-wide `prefer_tempaddr` sysctl per socket; `0` selects the stable
/// address. Linux and Android implement RFC 5014 instead.
#[cfg(apple)]
const STABLE_IPV6_SOURCE_OPTION: (libc::c_int, libc::c_int) = (63, 0);
#[cfg(any(target_os = "linux", target_os = "android"))]
const STABLE_IPV6_SOURCE_OPTION: (libc::c_int, libc::c_int) =
    (libc::IPV6_ADDR_PREFERENCES, libc::IPV6_PREFER_SRC_PUBLIC);

/// Prefers a stable IPv6 source address over a temporary (RFC 8981) one for this socket.
///
/// The kernel selects the source address for every socket that does not pin one: per
/// `connect` for connected sockets and per datagram for unconnected ones, and it prefers
/// temporary addresses by default. Temporary addresses rotate periodically, which
/// silently changes the selected source: connected sockets keep their now-deprecated
/// address until it is removed and sends fail with `EADDRNOTAVAIL`, and every rotation
/// changes the host candidate our peers learn, costing us relay allocations and
/// connectivity re-checks. The stable address lives as long as the network attachment
/// itself, which is exactly the lifetime of our sockets.
///
/// Failure is logged and otherwise ignored: without the preference the socket still
/// works, it merely keeps following the rotating addresses.
fn prefer_stable_ipv6_source(socket: &socket2::Socket) {
    #[cfg(any(apple, target_os = "linux", target_os = "android"))]
    {
        use std::os::fd::AsRawFd as _;

        let (option, value) = STABLE_IPV6_SOURCE_OPTION;

        // SAFETY: `value` outlives the call and the option length matches its type.
        let ret = unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::IPPROTO_IPV6,
                option,
                &value as *const libc::c_int as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            )
        };

        if ret != 0 {
            let error = io::Error::last_os_error();

            tracing::warn!(%error, "Failed to prefer stable IPv6 source address");
        }
    }

    #[cfg(not(any(apple, target_os = "linux", target_os = "android")))]
    let _ = socket;
}

pub struct TcpSocket {
    inner: tokio::net::TcpSocket,
    /// A location to store additional data with the [`TcpSocket`].
    backpack: Option<Box<dyn Any + Send + Sync + Unpin + 'static>>,
}

impl TcpSocket {
    pub async fn connect(self, addr: SocketAddr) -> io::Result<TcpStream> {
        let tcp_stream = self.inner.connect(addr).await?;

        Ok(TcpStream {
            inner: tcp_stream,
            _backpack: self.backpack,
        })
    }

    pub fn bind(&self, addr: SocketAddr) -> io::Result<()> {
        self.inner.bind(addr)
    }

    /// Pack some custom data into the backpack of this [`TcpSocket`].
    ///
    /// The data will be carried around until the [`TcpSocket`] is dropped.
    pub fn pack(&mut self, luggage: impl Any + Send + Sync + Unpin + 'static) {
        self.backpack = Some(Box::new(luggage));
    }
}

pub struct TcpStream {
    inner: tokio::net::TcpStream,
    /// A location to store additional data with the [`TcpStream`].
    _backpack: Option<Box<dyn Any + Send + Sync + Unpin + 'static>>,
}

impl tokio::io::AsyncWrite for TcpStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<Result<usize, io::Error>> {
        Pin::new(&mut self.as_mut().inner).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), io::Error>> {
        Pin::new(&mut self.as_mut().inner).poll_flush(cx)
    }

    fn poll_shutdown(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Result<(), io::Error>> {
        Pin::new(&mut self.as_mut().inner).poll_shutdown(cx)
    }
}

impl tokio::io::AsyncRead for TcpStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.as_mut().inner).poll_read(cx, buf)
    }
}

#[cfg(unix)]
impl std::os::fd::AsRawFd for TcpSocket {
    fn as_raw_fd(&self) -> std::os::fd::RawFd {
        self.inner.as_raw_fd()
    }
}

#[cfg(unix)]
impl std::os::fd::AsFd for TcpSocket {
    fn as_fd(&self) -> std::os::fd::BorrowedFd<'_> {
        self.inner.as_fd()
    }
}

pub struct UdpSocket {
    inner: tokio::net::UdpSocket,
    source_ip_resolver:
        Option<Box<dyn Fn(IpAddr) -> std::io::Result<IpAddr> + Send + Sync + 'static>>,
    port: u16,
}

/// A UDP socket with performance optimisations for fast send & receive.
pub struct PerfUdpSocket {
    /// The socket(s) we send and receive on; see [`SocketPool`].
    pool: SocketPool,

    /// The pools backing batched receives; see [`RecvBuffers`].
    recv_buffers: RecvBuffers,

    batch_histogram: opentelemetry::metrics::Histogram<u64>,
    send_retry_histogram: opentelemetry::metrics::Histogram<u64>,
    source_ip_resolver:
        Option<Box<dyn Fn(IpAddr) -> std::io::Result<IpAddr> + Send + Sync + 'static>>,
    port: u16,
}

impl UdpSocket {
    fn new(inner: tokio::net::UdpSocket) -> io::Result<Self> {
        let socket_addr = inner.local_addr()?;
        let port = socket_addr.port();

        Ok(UdpSocket {
            port,
            inner,
            source_ip_resolver: None,
        })
    }

    /// Upgrade this [`UdpSocket`] to a [`PerfUdpSocket`] for optimized IO.
    pub fn into_perf(self) -> io::Result<PerfUdpSocket> {
        let socket_addr = self.inner.local_addr()?;

        let quinn_ref = quinn_udp::UdpSockRef::from(&self.inner);
        let quinn_state = quinn_udp::UdpSocketState::new(quinn_ref)?;

        #[cfg(apple)]
        // SAFETY: All versions of MacOS / iOS that we tested support these APIs.
        unsafe {
            quinn_state.set_apple_fast_path();
        }

        // A single `recv` may receive several datagrams coalesced into one buffer via
        // generic receive offload (GRO). The kernel coalesces up to `gro_segments`
        // datagrams of at most `MAX_FZ_PAYLOAD` bytes each, so the buffer must be large
        // enough to hold that entire batch. On platforms without GRO `gro_segments` is 1,
        // sizing the buffer to a single datagram.
        let recv_buf_size = ip_packet::MAX_FZ_PAYLOAD * quinn_state.gro_segments();

        let wildcard = OwnedSocket::new(self.inner, quinn_state, false);

        Ok(PerfUdpSocket {
            pool: SocketPool::new(wildcard),
            recv_buffers: RecvBuffers::new(
                recv_buf_size,
                match socket_addr.ip() {
                    IpAddr::V4(_) => "udp-socket-v4",
                    IpAddr::V6(_) => "udp-socket-v6",
                },
            ),
            batch_histogram: otel_instruments::network_packets_batch_count(),
            send_retry_histogram: otel_instruments::network_retries(),
            source_ip_resolver: self.source_ip_resolver,
            port: self.port,
        })
    }

    /// Configures a new source IP resolver for this UDP socket.
    ///
    /// In case [`DatagramOut::src`] is [`None`], this function will be used to set a source IP given the destination IP of the datagram.
    /// If set, this function will be called for _every_ packet and should therefore be fast.
    ///
    /// Errors during resolution result in the packet being dropped.
    pub fn with_source_ip_resolver(
        mut self,
        resolver: Box<dyn Fn(IpAddr) -> std::io::Result<IpAddr> + Send + Sync + 'static>,
    ) -> Self {
        self.source_ip_resolver = Some(resolver);
        self
    }
}

#[cfg(unix)]
impl std::os::fd::AsRawFd for UdpSocket {
    fn as_raw_fd(&self) -> std::os::fd::RawFd {
        self.inner.as_raw_fd()
    }
}

#[cfg(unix)]
impl std::os::fd::AsFd for UdpSocket {
    fn as_fd(&self) -> std::os::fd::BorrowedFd<'_> {
        self.inner.as_fd()
    }
}

/// An inbound UDP datagram.
#[derive(Debug)]
pub struct DatagramIn<'a> {
    pub local: SocketAddr,
    pub from: SocketAddr,
    pub packet: &'a [u8],
    pub ecn: Ecn,
}

/// An outbound UDP datagram.
pub struct DatagramOut {
    pub src: Option<SocketAddr>,
    pub dst: SocketAddr,
    pub packet: Buffer<BytesMut>,
    pub segment_size: usize,
    pub ecn: Ecn,
}

impl PerfUdpSocket {
    /// Receives a batch of datagrams from whichever of our sockets becomes ready first.
    pub async fn recv_from(&self) -> Result<DatagramSegmentIter> {
        std::future::poll_fn(|cx| {
            self.pool
                .poll_recv(cx, |socket| self.try_recv_batch(socket))
        })
        .await
    }

    /// Attempts to receive a batch of datagrams from the given socket without blocking.
    ///
    /// Returns `WouldBlock` if the socket is not readable, clearing tokio's cached
    /// readiness in the process so that waiting for readiness actually suspends.
    fn try_recv_batch(&self, socket: Socket<'_>) -> io::Result<DatagramSegmentIter> {
        let mut batch = self.recv_buffers.pull_batch();

        let len = socket.inner.try_io(Interest::READABLE, || {
            // The loop only re-iterates on Apple, where connected sockets surface (one-shot)
            // ICMP errors on receive that we skip past; hence the `never_loop` allow elsewhere.
            #[cfg_attr(not(apple), allow(clippy::never_loop))]
            loop {
                let (mut io_bufs, metas) = batch.recv_slices();

                match socket.recv(&mut io_bufs, metas) {
                    // Connected sockets surface (one-shot) ICMP errors on receive; they are not fatal.
                    #[cfg(apple)]
                    Err(e) if socket.connected && is_icmp_unreachable(&e) => {
                        tracing::trace!("Ignoring ICMP error on connected UDP socket: {e}");
                        continue;
                    }
                    result => break result,
                }
            }
        })?;

        self.batch_histogram.record(
            len as u64,
            &[
                KeyValue::new("network.transport", "udp"),
                KeyValue::new("network.io.direction", "receive"),
            ],
        );

        Ok(DatagramSegmentIter::new(
            batch.buffers,
            batch.metas,
            self.port,
            len,
        ))
    }

    pub async fn send(&self, datagram: DatagramOut) -> Result<()> {
        let transmit = self.prepare_transmit(
            datagram.dst,
            datagram.src.map(|s| s.ip()),
            datagram.packet.chunk(),
            datagram.segment_size,
            datagram.ecn,
        )?;

        let pooled = self
            .pool
            .get_send_socket(transmit.src_ip, datagram.dst, &self.recv_buffers);

        self.send_transmit(pooled.as_socket(), &transmit).await
    }

    /// The number of connected per-destination "flow" sockets currently cached.
    ///
    /// Exposed for integration tests. Always `0` on non-Apple platforms, where all
    /// traffic uses the single catch-all socket.
    #[doc(hidden)]
    pub fn flow_socket_count(&self) -> usize {
        self.pool.flow_socket_count()
    }

    pub fn set_buffer_sizes(
        &mut self,
        requested_send_buffer_size: usize,
        requested_recv_buffer_size: usize,
    ) {
        self.pool.set_buffer_sizes(
            requested_send_buffer_size,
            requested_recv_buffer_size,
            self.port,
        );
    }

    /// Sends a [`Transmit`] over the given socket, chunked to honor GSO limits.
    ///
    /// Connected sockets participate in Darwin's flow advisories: under congestion the kernel
    /// drops the datagram, returns `ENOBUFS` and fails all further sends instantly until the
    /// interface queue drains, which it signals via write-readiness. For those, we park until
    /// that signal instead of spinning.
    async fn send_transmit(&self, socket: Socket<'_>, transmit: &Transmit<'_>) -> Result<()> {
        let segment_size = transmit
            .segment_size
            .expect("`segment_size` must always be set");
        // On a connected socket the source is pinned by the binding, so we drop the cmsg.
        let src = if socket.connected {
            None
        } else {
            transmit.src_ip
        };
        let dst = transmit.destination;

        let total = transmit.contents.len();

        // Offset of the next byte that still needs to be sent. On a retryable error
        // we resume from here instead of restarting the whole transmit, so a batch
        // the kernel already accepted is never re-sent.
        let mut offset = 0;
        let mut attempt = 0;

        while offset < total {
            // Recompute every iteration: an `EIO` makes `quinn-udp` disable GSO, so
            // the remaining data needs to be re-split into smaller batches.
            let chunk_size = self.calculate_chunk_size(socket.state, segment_size, dst)?;

            let end = std::cmp::min(offset + chunk_size, total);
            let contents = &transmit.contents[offset..end];

            let chunk = Transmit {
                destination: dst,
                ecn: transmit.ecn,
                contents,
                segment_size: Some(segment_size),
                src_ip: src,
            };

            #[cfg(debug_assertions)]
            tracing::trace!(target: "wire::net::send", ?src, %dst, ecn = ?chunk.ecn, num_packets = %(contents.len() / segment_size), %segment_size, connected = %socket.connected);

            let result = if socket.connected {
                // Connected sockets never return `EWOULDBLOCK` on Darwin; issue the syscall
                // directly instead of going through tokio's (always-set) write-readiness.
                socket
                    .state
                    .try_send(UdpSockRef::from(socket.inner), &chunk)
            } else {
                socket
                    .inner
                    .async_io(Interest::WRITABLE, || {
                        socket
                            .state
                            .try_send(UdpSockRef::from(socket.inner), &chunk)
                    })
                    .await
            };

            match result {
                Ok(()) => {
                    self.record_send_batch_size(contents.len() / segment_size);
                    self.record_send_retries(attempt);

                    offset = end;
                    attempt = 0; // Each batch gets its own retry budget.
                }
                // Connected sockets get a write-readiness wakeup from the kernel's flow advisory
                // once the interface queue drains, so we park until then.
                #[cfg(apple)]
                Err(e) if socket.connected && should_retry(&e, attempt) => {
                    wait_for_send_capacity(socket.inner).await;
                    attempt += 1;
                }
                // The unconnected catch-all gets no such signal; spin, since the `ENOBUFS`
                // clears off-thread (driver / NIC) within microseconds.
                Err(e) if should_retry(&e, attempt) => {
                    spin_and_yield(attempt).await;
                    attempt += 1;
                }
                #[cfg(apple)]
                Err(e) if socket.connected && is_icmp_unreachable(&e) => {
                    self.record_send_retries(attempt);

                    // The kernel received an ICMP error for this path; the error is one-shot.
                    // Drop the packet: either the path recovers or connlib migrates / times out.
                    tracing::debug!(%dst, "Dropping packet for unreachable destination: {e}");

                    return Ok(());
                }
                Err(e) => {
                    self.record_send_retries(attempt);

                    return Err(e).with_context(|| {
                        format!(
                            "Failed to send {} bytes at offset {offset}/{total} with segment_size {segment_size} to {dst}",
                            contents.len()
                        )
                    });
                }
            }
        }

        Ok(())
    }

    /// Records the number of segments sent in a single batched syscall.
    fn record_send_batch_size(&self, num_segments: usize) {
        self.batch_histogram.record(
            num_segments as u64,
            &[
                KeyValue::new("network.transport", "udp"),
                KeyValue::new("network.io.direction", "transmit"),
            ],
        );
    }

    /// Records how many times a single batch had to be retried before it went through or was dropped.
    ///
    /// Batches that succeed on the first try (the common case) are not recorded, keeping the hot path cheap.
    fn record_send_retries(&self, attempt: u32) {
        if attempt == 0 {
            return;
        }

        self.send_retry_histogram.record(
            attempt as u64,
            &[
                KeyValue::new("network.transport", "udp"),
                KeyValue::new("network.io.direction", "transmit"),
            ],
        );
    }

    /// Calculate the chunk size for a given segment size.
    ///
    /// At most, an IP packet can 65535 (`u16::MAX`) bytes.
    /// To know the maximum size we can pass as the UDP payload, we need to subtract the IP and UDP header length as overhead.
    ///
    /// In case GSO is not supported at all by the kernel, `quinn_udp` will detect this and set `max_gso_segments` to 1.
    /// We need to honor both of these constraints when calculating the chunk size.
    ///
    /// Fails if `segment_size` exceeds the maximum UDP payload, in which case not even a single segment fits.
    fn calculate_chunk_size(
        &self,
        state: &quinn_udp::UdpSocketState,
        segment_size: usize,
        dst: SocketAddr,
    ) -> Result<usize> {
        let header_overhead = match dst {
            SocketAddr::V4(_) => Ipv4Header::MAX_LEN + UdpHeader::LEN,
            SocketAddr::V6(_) => Ipv6Header::LEN + UdpHeader::LEN,
        };

        let max_segments_by_config = state.max_gso_segments();
        let max_segments_by_size = (u16::MAX as usize - header_overhead) / segment_size;

        let max_segments = std::cmp::min(max_segments_by_config, max_segments_by_size);

        anyhow::ensure!(
            max_segments > 0,
            "segment_size {segment_size} exceeds the maximum UDP payload for {dst}"
        );

        Ok(segment_size * max_segments)
    }

    fn prepare_transmit<'a>(
        &self,
        dst: SocketAddr,
        src_ip: Option<IpAddr>,
        packet: &'a [u8],
        segment_size: usize,
        ecn: Ecn,
    ) -> Result<quinn_udp::Transmit<'a>> {
        let src_ip = match src_ip {
            Some(src_ip) => Some(src_ip),
            None => self.resolve_source_for(dst.ip()).with_context(|| {
                format!(
                    "Failed to select egress interface for packet to {}",
                    dst.ip()
                )
            })?,
        };

        let transmit = quinn_udp::Transmit {
            destination: dst,
            ecn: match ecn {
                Ecn::NonEct => None,
                Ecn::Ect1 => Some(quinn_udp::EcnCodepoint::Ect1),
                Ecn::Ect0 => Some(quinn_udp::EcnCodepoint::Ect0),
                Ecn::Ce => Some(quinn_udp::EcnCodepoint::Ce),
            },
            contents: packet,
            segment_size: Some(segment_size),
            src_ip,
        };

        Ok(transmit)
    }

    /// Attempt to resolve the source IP to use for sending to the given destination IP.
    fn resolve_source_for(&self, dst: IpAddr) -> std::io::Result<Option<IpAddr>> {
        let Some(resolver) = self.source_ip_resolver.as_ref() else {
            // If we don't have a resolver, let the operating system decide.
            return Ok(None);
        };

        let src = (resolver)(dst)?;

        Ok(Some(src))
    }
}

impl UdpSocket {
    /// Performs a single request-response handshake with the specified destination socket address.
    ///
    /// This consumes `self` because we want to enforce that we only receive a single message on this socket.
    /// UDP is stateless and therefore, anybody can just send a packet to the destination.
    ///
    /// To simulate a handshake, we therefore only wait for a single message arriving on this socket,
    /// after that, we discard it, freeing up the used source port.
    ///
    /// This is similar to the `connect` functionality but that one doesn't seem to work reliably in a cross-platform way.
    pub async fn handshake<const BUF_SIZE: usize>(
        self,
        dst: SocketAddr,
        payload: &[u8],
    ) -> io::Result<Vec<u8>> {
        self.inner.send_to(payload, dst).await?;

        let mut buffer = vec![0u8; BUF_SIZE];

        let (num_received, sender) = self.inner.recv_from(&mut buffer).await?;

        // Even though scopes are technically important for link-local IPv6 addresses, they can be ignored for our purposes.
        // We only want to ensure that the reply is from the expected source after we have already received the packet.
        if !is_equal_modulo_scope_for_ipv6_link_local(dst, sender) {
            return Err(io::Error::other(format!(
                "Unexpected reply source: {sender}; expected: {dst}"
            )));
        }

        buffer.truncate(num_received);

        Ok(buffer)
    }
}

/// Applies the requested buffer size to a socket, halving it until the kernel accepts it.
///
/// Apple platforms reject buffer sizes above `kern.ipc.maxsockbuf` with `ENOBUFS` instead of
/// clamping them like Linux does.
pub(crate) fn apply_buffer_size(
    requested: usize,
    mut set: impl FnMut(usize) -> io::Result<()>,
) -> io::Result<()> {
    /// Buffer sizes below this are not worth trading for an error message; all platforms accept it.
    const FLOOR: usize = 64 * 1024;

    let mut size = requested;

    loop {
        match set(size) {
            Ok(()) => return Ok(()),
            Err(_) if size > FLOOR => size /= 2,
            Err(e) => return Err(e),
        }
    }
}

/// Compares the two [`SocketAddr`]s for equality, ignored IPv6 scopes for link-local addresses.
fn is_equal_modulo_scope_for_ipv6_link_local(expected: SocketAddr, actual: SocketAddr) -> bool {
    match (expected, actual) {
        (SocketAddr::V6(expected), SocketAddr::V6(mut actual))
            if expected.scope_id() == 0 && actual.ip().is_unicast_link_local() =>
        {
            actual.set_scope_id(0);

            expected == actual
        }
        (SocketAddr::V4(expected), SocketAddr::V4(actual)) => expected == actual,
        (SocketAddr::V6(expected), SocketAddr::V6(actual)) => expected == actual,
        (SocketAddr::V6(_), SocketAddr::V4(_)) | (SocketAddr::V4(_), SocketAddr::V6(_)) => false,
    }
}

/// Whether the error originates from an ICMP message for a connected socket's path.
#[cfg(apple)]
fn is_icmp_unreachable(e: &io::Error) -> bool {
    matches!(
        e.raw_os_error(),
        Some(
            libc::ECONNREFUSED
                | libc::EHOSTUNREACH
                | libc::ENETUNREACH
                | libc::EHOSTDOWN
                | libc::ENETDOWN
        )
    )
}

/// Whether a failed send should be retried for the given attempt.
fn should_retry(e: &io::Error, attempt: u32) -> bool {
    let Some(raw_os_error) = e.raw_os_error() else {
        return false;
    };

    // On Linux / Android, `EIO` or `EINVAL` means `quinn-udp` just disabled GSO; we retry
    // once to re-send the data split into smaller batches.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    if (raw_os_error == libc::EIO || raw_os_error == libc::EINVAL) && attempt < 1 {
        return true;
    }

    // On MacOS / iOS, the kernel returns `ENOBUFS` when the interface queue fills up.
    #[cfg(apple)]
    if raw_os_error == libc::ENOBUFS && attempt < MAX_ENOBUFS_RETRIES {
        return true;
    }

    // On Windows, error 10055 is the equivalent of `ENOBUFS`; same transient condition.
    #[cfg(target_os = "windows")]
    if raw_os_error == WINDOWS_ENOBUFS && attempt < MAX_ENOBUFS_RETRIES {
        return true;
    }

    false
}

/// Briefly back off after a retryable send error before trying again.
///
/// We avoid `tokio::time::sleep`: its timer wheel rounds up to ~1ms (~15ms on
/// Windows), far longer than the microseconds an `ENOBUFS` needs to clear. Instead
/// we spin a few (escalating) times and then cooperatively yield. The yield matters:
/// send and receive share a single-threaded runtime, so a pure spin would starve the
/// receive task.
async fn spin_and_yield(attempt: u32) {
    for _ in 0..(1u32 << attempt.min(SPIN_LIMIT)) {
        std::hint::spin_loop();
    }

    tokio::task::yield_now().await;
}

/// Parks until the kernel signals send capacity on the given (connected) socket, bounded by a timeout.
///
/// After a flow-advisory `ENOBUFS`, the kernel marks the socket not-writable and fires
/// `EVFILT_WRITE` once the interface queue drains. tokio's cached write-readiness is stale
/// at that point (UDP sends never return `EWOULDBLOCK` on Darwin, so it is never cleared),
/// which is why we clear it explicitly before parking.
///
/// The timeout is a liveness backstop: `ENOBUFS` without a flow advisory (e.g. from mbuf
/// exhaustion) never produces a wakeup. An early timeout merely costs one failed send
/// before we park again.
#[cfg(apple)]
async fn wait_for_send_capacity(socket: &tokio::net::UdpSocket) {
    let _ = socket.try_io(Interest::WRITABLE, || {
        Err::<(), io::Error>(io::ErrorKind::WouldBlock.into())
    });

    let timeout = std::time::Duration::from_millis(10);
    let _ = tokio::time::timeout(timeout, socket.writable()).await;
}

/// The pools backing a batched receive: scratch space for the datagrams themselves
/// plus containers for the buffers and metas that make up one batch.
///
/// The buffers and metas live in pooled, heap-allocated `Vec`s rather than inline in
/// [`DatagramSegmentIter`]: the iterator is sent over a channel and inline storage
/// would make every channel slot (and thus tokio's block allocations) carry the full
/// batch size.
pub(crate) struct RecvBuffers {
    bytes: BufferPool<Vec<u8>>,
    buffers: BufferPool<VecBuf<Buffer<Vec<u8>>>>,
    metas: BufferPool<VecBuf<quinn_udp::RecvMeta>>,
}

/// The pooled storage for one receive batch: a datagram buffer plus its metadata per slot.
pub(crate) struct RecvBatch {
    buffers: Buffer<VecBuf<Buffer<Vec<u8>>>>,
    metas: Buffer<VecBuf<quinn_udp::RecvMeta>>,
}

impl RecvBatch {
    /// The batch's datagram buffers as scatter slices, paired with the meta array the
    /// kernel fills in — the two arguments a `recvmmsg`-style read expects. Borrows the
    /// batch for the duration of the read; afterwards the buffers are handed to a
    /// [`DatagramSegmentIter`].
    fn recv_slices(
        &mut self,
    ) -> (
        SmallVec<[IoSliceMut<'_>; quinn_udp::BATCH_SIZE]>,
        &mut [quinn_udp::RecvMeta],
    ) {
        let io_bufs = self
            .buffers
            .iter_mut()
            .map(|b| IoSliceMut::new(b))
            .collect();

        (io_bufs, &mut self.metas)
    }
}

impl RecvBuffers {
    fn new(recv_buf_size: usize, tag: &'static str) -> Self {
        Self {
            bytes: BufferPool::new(recv_buf_size, tag),
            buffers: BufferPool::new(quinn_udp::BATCH_SIZE, "udp-recv-buffers"),
            metas: BufferPool::new(quinn_udp::BATCH_SIZE, "udp-recv-metas"),
        }
    }

    /// Pulls the storage for one receive batch, sized and ready for a `recv` call.
    pub(crate) fn pull_batch(&self) -> RecvBatch {
        let mut buffers = self.buffers.pull();
        let mut metas = self.metas.pull();

        buffers.extend(std::iter::repeat_with(|| self.bytes.pull()).take(quinn_udp::BATCH_SIZE));
        metas.resize(quinn_udp::BATCH_SIZE, quinn_udp::RecvMeta::default());

        RecvBatch { buffers, metas }
    }
}

/// An iterator that segments a batch of buffers into individual datagrams.
///
/// This iterator is generic over its buffer type to allow easier testing without a buffer pool.
///
/// This implementation might look like dark arts but it is actually quite simple.
/// Its design is driven by two main ideas:
///
/// - We want the return a single `Iterator`-like type from a `recv` call on the socket.
/// - We want to avoid copying buffers around.
///
/// To achieve this, this type doesn't implement `Iterator` but `LendingIterator` instead.
/// A `LendingIterator` adds a lifetime to the `Item` type, allowing us to return a reference to something the iterator owns.
///
/// Composing `LendingIterator`s itself is difficult which is why we implement the entire segmentation of the buffers within a single type.
/// When [`quinn_udp`] returns us the buffers, it will have populated the [`quinn_udp::RecvMeta`]s accordingly.
/// Thus, our main job within this iterator is to loop over the `buffers` and `meta` pair-wise, inspect the `meta` and segment the data within the buffer accordingly.
#[derive(derive_more::Debug)]
pub struct DatagramSegmentIter<B = Buffer<Vec<u8>>> {
    #[debug(skip)]
    buffers: Buffer<VecBuf<B>>,
    #[debug(skip)]
    metas: Buffer<VecBuf<quinn_udp::RecvMeta>>,

    port: u16,

    buf_index: usize,
    segment_index: usize,

    _total_bytes: usize,
    _num_packets: usize,
}

impl<B> DatagramSegmentIter<B> {
    pub(crate) fn new(
        mut buffers: Buffer<VecBuf<B>>,
        mut metas: Buffer<VecBuf<quinn_udp::RecvMeta>>,
        port: u16,
        len: usize,
    ) -> Self {
        // Drop the unused buffers / metas.
        buffers.truncate(len);
        metas.truncate(len);

        let total_bytes = metas.iter().map(|m| m.len).sum::<usize>();
        let num_packets = metas
            .iter()
            .map(|meta| {
                if meta.len == 0 {
                    return 0;
                }

                meta.len / meta.stride
            })
            .sum::<usize>();

        Self {
            buffers,
            metas,
            port,
            buf_index: 0,
            segment_index: 0,
            _total_bytes: total_bytes,
            _num_packets: num_packets,
        }
    }
}

impl<B> LendingIterator for DatagramSegmentIter<B>
where
    B: Deref<Target = Vec<u8>> + 'static,
{
    type Item<'a> = DatagramIn<'a>;

    fn next(&mut self) -> Option<Self::Item<'_>> {
        loop {
            if self.buf_index >= self.buffers.len() {
                return None;
            }

            let buf = &self.buffers[self.buf_index];
            let meta = &self.metas[self.buf_index];

            if meta.len == 0 {
                self.buf_index += 1;
                continue;
            }

            let Some(local_ip) = meta.dst_ip else {
                tracing::warn!("Skipping packet without local IP");

                self.buf_index += 1;
                continue;
            };

            match meta.stride.cmp(&meta.len) {
                std::cmp::Ordering::Equal | std::cmp::Ordering::Less => {}
                std::cmp::Ordering::Greater => {
                    tracing::warn!(
                        "stride ({}) is larger than buffer len ({})",
                        meta.stride,
                        meta.len
                    );

                    self.buf_index += 1;
                    continue;
                }
            }

            if self.segment_index >= meta.len {
                self.buf_index += 1;
                self.segment_index = 0;
                continue;
            }

            let local = SocketAddr::new(local_ip, self.port);

            let segment_size = meta.stride;

            #[cfg(debug_assertions)]
            tracing::trace!(target: "wire::net::recv", num_p = %self._num_packets, tot_b = %self._total_bytes, src = %meta.addr, dst = %local, ecn = ?meta.ecn, len = %segment_size);

            let segment_start = self.segment_index;
            let segment_end = std::cmp::min(segment_start + segment_size, meta.len);

            self.segment_index += segment_size;

            return Some(DatagramIn {
                local,
                from: meta.addr,
                packet: &buf[segment_start..segment_end],
                ecn: match meta.ecn {
                    Some(EcnCodepoint::Ce) => Ecn::Ce,
                    Some(EcnCodepoint::Ect0) => Ecn::Ect0,
                    Some(EcnCodepoint::Ect1) => Ecn::Ect1,
                    None => Ecn::NonEct,
                },
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use gat_lending_iterator::LendingIterator as _;
    use quinn_udp::RecvMeta;
    use std::net::{Ipv4Addr, Ipv6Addr, SocketAddrV6};

    use super::*;

    #[cfg(any(apple, target_os = "linux"))]
    #[test]
    fn stable_ipv6_source_preference_sticks() {
        use std::os::fd::AsRawFd as _;

        let Ok(socket) = socket2::Socket::new(socket2::Domain::IPV6, socket2::Type::DGRAM, None)
        else {
            eprintln!("skipping; environment has no IPv6 support");
            return;
        };

        prefer_stable_ipv6_source(&socket);

        let (option, expected) = STABLE_IPV6_SOURCE_OPTION;
        let mut value: libc::c_int = -1;
        let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;

        // SAFETY: `value` and `len` outlive the call and match the option's type.
        let ret = unsafe {
            libc::getsockopt(
                socket.as_raw_fd(),
                libc::IPPROTO_IPV6,
                option,
                &mut value as *mut libc::c_int as *mut libc::c_void,
                &mut len,
            )
        };

        assert_eq!(ret, 0);
        assert_eq!(value, expected);
    }

    #[derive(derive_more::Deref)]
    struct DummyBuffer(Vec<u8>);

    impl Clone for DummyBuffer {
        fn clone(&self) -> Self {
            Self(self.0.clone())
        }
    }

    /// The iterator is the item of the channel to the main thread; keeping it small is
    /// the whole point of storing the batch in pooled `Vec`s rather than inline. tokio
    /// allocates channel slots in blocks, so a large item would cross musl's mmap
    /// threshold and thrash the allocator (see the pooling that produced this type).
    #[cfg(target_pointer_width = "64")]
    #[test]
    fn iter_is_a_small_channel_item() {
        assert_eq!(size_of::<DatagramSegmentIter>(), 104);
    }

    #[test]
    fn datagram_iter_segments_buffer_correctly() {
        let buffer_pool = BufferPool::<VecBuf<DummyBuffer>>::new(3, "test");
        let meta_pool = BufferPool::<VecBuf<quinn_udp::RecvMeta>>::new(3, "test");

        let mut buffers = buffer_pool.pull();
        buffers.extend([
            DummyBuffer(b"foobar1foobar2foobar3foobar4foobar5foo                 ".to_vec()),
            DummyBuffer(b"baz1baz2baz3baz4baz5foo       ".to_vec()),
            DummyBuffer(b"".to_vec()),
        ]);

        let mut metas = meta_pool.pull();
        metas.extend([
            recv_meta(
                SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
                IpAddr::V4(Ipv4Addr::LOCALHOST),
                38,
                7,
            ),
            recv_meta(
                SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
                IpAddr::V4(Ipv4Addr::LOCALHOST),
                23,
                4,
            ),
            quinn_udp::RecvMeta::default(),
        ]);

        let mut iter = DatagramSegmentIter::new(buffers, metas, 0, 3);

        assert_eq!(iter.next().unwrap().packet, b"foobar1");
        assert_eq!(iter.next().unwrap().packet, b"foobar2");
        assert_eq!(iter.next().unwrap().packet, b"foobar3");
        assert_eq!(iter.next().unwrap().packet, b"foobar4");
        assert_eq!(iter.next().unwrap().packet, b"foobar5");
        assert_eq!(iter.next().unwrap().packet, b"foo");
        assert_eq!(iter.next().unwrap().packet, b"baz1");
        assert_eq!(iter.next().unwrap().packet, b"baz2");
        assert_eq!(iter.next().unwrap().packet, b"baz3");
        assert_eq!(iter.next().unwrap().packet, b"baz4");
        assert_eq!(iter.next().unwrap().packet, b"baz5");
        assert_eq!(iter.next().unwrap().packet, b"foo");
        assert!(iter.next().is_none());
    }

    #[test]
    fn scopes_are_ignored_for_link_local_addresses() {
        let left = SocketAddr::V6(SocketAddrV6::new(
            Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 0),
            1000,
            0,
            0,
        ));
        let right = SocketAddr::V6(SocketAddrV6::new(
            Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 0),
            1000,
            0,
            42,
        ));

        assert!(is_equal_modulo_scope_for_ipv6_link_local(left, right))
    }

    #[test]
    fn apply_buffer_size_halves_until_accepted() {
        let mut attempts = Vec::new();

        let result = apply_buffer_size(1024 * 1024, |size| {
            attempts.push(size);

            if size > 256 * 1024 {
                return Err(io::Error::other("too big"));
            }

            Ok(())
        });

        assert!(result.is_ok());
        assert_eq!(attempts, vec![1024 * 1024, 512 * 1024, 256 * 1024]);
    }

    #[test]
    fn apply_buffer_size_gives_up_at_floor() {
        let result = apply_buffer_size(256 * 1024, |_| Err(io::Error::other("nope")));

        assert!(result.is_err());
    }

    #[test]
    fn does_not_retry_non_os_errors() {
        let err = io::Error::other("not an os error");

        assert!(!should_retry(&err, 0));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn retries_gso_errors_once() {
        for raw in [libc::EIO, libc::EINVAL] {
            let err = io::Error::from_raw_os_error(raw);

            assert!(should_retry(&err, 0));
            assert!(!should_retry(&err, 1));
        }
    }

    #[test]
    #[cfg(apple)]
    fn retries_enobufs_at_most_24_times() {
        let err = io::Error::from_raw_os_error(libc::ENOBUFS);

        assert!(should_retry(&err, 23));
        assert!(!should_retry(&err, 24));
    }

    #[test]
    #[cfg(target_os = "windows")]
    fn windows_10055_error() {
        let err = io::Error::from_raw_os_error(WINDOWS_ENOBUFS);

        assert_eq!(
            err.to_string(),
            "An operation on a socket could not be performed because the system lacked sufficient buffer space or because a queue was full. (os error 10055)"
        );
    }

    fn recv_meta(addr: SocketAddr, dst_ip: IpAddr, len: usize, stride: usize) -> RecvMeta {
        let mut meta = RecvMeta::default();
        meta.addr = addr;
        meta.dst_ip = Some(dst_ip);
        meta.len = len;
        meta.stride = stride;

        meta
    }
}
