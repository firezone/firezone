use anyhow::{Context as _, Result};
use bufferpool::{Buffer, BufferPool};
use bytes::{Buf as _, BytesMut};
use gat_lending_iterator::LendingIterator;
use ip_packet::{Ecn, Ipv4Header, Ipv6Header, UdpHeader};
use opentelemetry::KeyValue;
use quinn_udp::{EcnCodepoint, Transmit, UdpSockRef};
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

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod apple;

pub trait SocketFactory<S>: Send + Sync + 'static {
    fn bind(&self, local: SocketAddr) -> io::Result<S>;
    fn reset(&self);
}

/// On Apple platforms, UDP sockets never buffer data in the send buffer: datagrams are
/// handed straight to the interface and `SO_SNDBUF` only acts as a cap on the maximum
/// datagram size. A large send buffer is therefore pointless (and cannot cause
/// bufferbloat either); 64 KiB comfortably covers the largest datagram we ever send.
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub const SEND_BUFFER_SIZE: usize = 64 * 1024;
#[cfg(not(any(target_os = "macos", target_os = "ios")))]
pub const SEND_BUFFER_SIZE: usize = 16 * ONE_MB;
pub const RECV_BUFFER_SIZE: usize = 128 * ONE_MB;
const ONE_MB: usize = 1024 * 1024;

/// How many times we at most try to re-send a packet if we encounter ENOBUFS on MacOS / iOS or 10055 on Windows.
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "windows"))]
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
    }

    socket.set_nonblocking(true)?;
    socket.bind(&addr)?;

    let socket = std::net::UdpSocket::from(socket);
    let socket = tokio::net::UdpSocket::try_from(socket)?;
    let socket = UdpSocket::new(socket)?;

    Ok(socket)
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

/// Uninhabited stand-in for a flow socket on platforms that don't have any.
#[cfg(not(any(target_os = "macos", target_os = "ios")))]
enum FlowSocketStub {}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
impl FlowSocketStub {
    fn socket(&self) -> &tokio::net::UdpSocket {
        match *self {}
    }

    fn state(&self) -> &quinn_udp::UdpSocketState {
        match *self {}
    }
}

/// A UDP socket with performance optimisations for fast send & receive.
pub struct PerfUdpSocket {
    inner: tokio::net::UdpSocket,
    state: quinn_udp::UdpSocketState,

    /// Connected per-destination sockets; Darwin's UDP fast path and flow advisories require connected sockets.
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    flow_sockets: apple::FlowSockets,

    /// A buffer pool for batches of incoming UDP packets.
    buffer_pool: BufferPool<Vec<u8>>,

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

        #[cfg(any(target_os = "macos", target_os = "ios"))]
        // SAFETY: All versions of MacOS / iOS that we tested support these APIs.
        unsafe {
            quinn_state.set_apple_fast_path();
        }

        Ok(PerfUdpSocket {
            inner: self.inner,
            state: quinn_state,
            #[cfg(any(target_os = "macos", target_os = "ios"))]
            flow_sockets: apple::FlowSockets::new(socket_addr),
            buffer_pool: BufferPool::new(
                u16::MAX as usize,
                match socket_addr.ip() {
                    IpAddr::V4(_) => "udp-socket-v4",
                    IpAddr::V6(_) => "udp-socket-v6",
                },
            ),
            batch_histogram: opentelemetry::global::meter("connlib")
                .u64_histogram("system.network.packets.batch_count")
                .with_description(
                    "How many batches of packets we have processed in a single syscall.",
                )
                .with_unit("{batches}")
                .with_boundaries((1..32_u64).map(|i| i as f64).collect())
                .build(),
            send_retry_histogram: opentelemetry::global::meter("connlib")
                .u64_histogram("system.network.retries")
                .with_description(
                    "How many times a UDP send was retried (spun) after a transient ENOBUFS-style error before it succeeded or was dropped.",
                )
                .with_unit("{retry}")
                .with_boundaries((1..=24_u64).map(|i| i as f64).collect())
                .build(),
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
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    pub async fn recv_from(&self) -> Result<DatagramSegmentIter> {
        self.recv_single(&self.inner, &self.state).await
    }

    /// Receives batches of datagrams from the catch-all socket and all flow sockets.
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    pub async fn recv_from(&self) -> Result<DatagramSegmentIter> {
        std::future::poll_fn(|cx| self.poll_recv_from(cx)).await
    }

    /// Multiplexes receiving over the catch-all socket and all flow sockets.
    ///
    /// This is the one place where async-await does not cut it: we need to check a
    /// runtime-variable number of sockets for readiness and suspend on all of them at once.
    /// Everything substantial happens in [`PerfUdpSocket::try_recv_batch`].
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    fn poll_recv_from(&self, cx: &mut Context<'_>) -> Poll<Result<DatagramSegmentIter>> {
        // Register the waker first: a flow socket connected after we inspect the
        // set below must still be able to wake us.
        self.flow_sockets.register_recv_waker(cx.waker());

        // Datagrams rescued from an evicted flow socket are the oldest; yield them first.
        if let Some(iter) = self.flow_sockets.pop_drained() {
            return Poll::Ready(Ok(iter));
        }

        let poll_order = self.flow_sockets.poll_order();

        if poll_order.catch_all_first()
            && let Poll::Ready(result) = self.poll_recv_socket(cx, &self.inner, &self.state)
        {
            return Poll::Ready(result);
        }

        for flow_socket in poll_order.sockets() {
            if let Poll::Ready(result) =
                self.poll_recv_socket(cx, flow_socket.socket(), flow_socket.state())
            {
                if result.is_ok() {
                    flow_socket.record_received(std::time::Instant::now());
                }

                return Poll::Ready(result);
            }
        }

        if !poll_order.catch_all_first()
            && let Poll::Ready(result) = self.poll_recv_socket(cx, &self.inner, &self.state)
        {
            return Poll::Ready(result);
        }

        Poll::Pending
    }

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    fn poll_recv_socket(
        &self,
        cx: &mut Context<'_>,
        socket: &tokio::net::UdpSocket,
        state: &quinn_udp::UdpSocketState,
    ) -> Poll<Result<DatagramSegmentIter>> {
        loop {
            match socket.poll_recv_ready(cx) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(Err(e)) => {
                    return Poll::Ready(
                        Err(e).context("Failed to wait for socket to become readable"),
                    );
                }
                Poll::Ready(Ok(())) => {}
            }

            match self.try_recv_batch(socket, state) {
                // The readiness was stale; `try_io` cleared it, so the next poll above suspends.
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue,
                result => return Poll::Ready(result.context("Failed to read from socket")),
            }
        }
    }

    /// Receives a batch of datagrams from the given socket.
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    async fn recv_single(
        &self,
        socket: &tokio::net::UdpSocket,
        state: &quinn_udp::UdpSocketState,
    ) -> Result<DatagramSegmentIter> {
        loop {
            socket
                .readable()
                .await
                .context("Failed to wait for socket to become readable")?;

            match self.try_recv_batch(socket, state) {
                // The readiness was stale; `try_io` cleared it, so the next wait above suspends.
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue,
                result => return result.context("Failed to read from socket"),
            }
        }
    }

    /// Attempts to receive a batch of datagrams from the given socket without blocking.
    ///
    /// Returns `WouldBlock` if the socket is not readable, clearing tokio's cached
    /// readiness in the process so that waiting for readiness actually suspends.
    fn try_recv_batch(
        &self,
        socket: &tokio::net::UdpSocket,
        state: &quinn_udp::UdpSocketState,
    ) -> io::Result<DatagramSegmentIter> {
        // Stack-allocate arrays for buffers and meta. The size is implied from the const-generic default on `DatagramSegmentIter`.
        let mut bufs = std::array::from_fn(|_| self.buffer_pool.pull());
        let mut meta = std::array::from_fn(|_| quinn_udp::RecvMeta::default());

        let len = socket.try_io(Interest::READABLE, || {
            // Fancy std-functions ahead: `each_mut` transforms our array into an array of references to our items and `map` allows us to create an `IoSliceMut` out of each element.
            // `state.recv` requires us to pass `IoSliceMut` but later on, we need the original buffer again because `DatagramSegmentIter` needs to own them.
            // That is why we cannot just create an `IoSliceMut` to begin with.
            let mut io_bufs = bufs.each_mut().map(|b| IoSliceMut::new(b));

            recv_swallowing_icmp_errors(state, socket, &mut io_bufs, &mut meta)
        })?;

        self.batch_histogram.record(
            len as u64,
            &[
                KeyValue::new("network.transport", "udp"),
                KeyValue::new("network.io.direction", "receive"),
            ],
        );

        Ok(DatagramSegmentIter::new(bufs, meta, self.port, len))
    }

    pub async fn send(&self, datagram: DatagramOut) -> Result<()> {
        let transmit = self.prepare_transmit(
            datagram.dst,
            datagram.src.map(|s| s.ip()),
            datagram.packet.chunk(),
            datagram.segment_size,
            datagram.ecn,
        )?;

        if let Some(flow_socket) = self.flow_socket(transmit.src_ip, datagram.dst) {
            let transmit = Transmit {
                // The source is pinned by the socket's binding; no need for a cmsg.
                src_ip: None,
                ..transmit
            };

            return self
                .send_transmit(flow_socket.socket(), flow_socket.state(), &transmit, true)
                .await;
        }

        self.send_transmit(&self.inner, &self.state, &transmit, false)
            .await
    }

    /// Returns the connected flow socket for the given `(src, dst)` pair, connecting a new one if needed.
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    fn flow_socket(
        &self,
        src: Option<IpAddr>,
        dst: SocketAddr,
    ) -> Option<std::sync::Arc<apple::FlowSocket>> {
        self.flow_sockets
            .get_or_connect(src, dst, &self.buffer_pool)
    }

    /// Flow sockets only exist on Apple platforms; everywhere else, all traffic uses the catch-all socket.
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    fn flow_socket(&self, _src: Option<IpAddr>, _dst: SocketAddr) -> Option<FlowSocketStub> {
        None
    }

    pub fn set_buffer_sizes(
        &mut self,
        requested_send_buffer_size: usize,
        requested_recv_buffer_size: usize,
    ) {
        let socket = socket2::SockRef::from(&self.inner);

        // Apply each direction independently: failing to set one buffer size must not prevent the other from being applied.
        if let Err(e) = apply_buffer_size(requested_send_buffer_size, |size| {
            socket.set_send_buffer_size(size)
        }) {
            tracing::warn!(%requested_send_buffer_size, "Failed to set send buffer size: {e}");
        }

        if let Err(e) = apply_buffer_size(requested_recv_buffer_size, |size| {
            socket.set_recv_buffer_size(size)
        }) {
            tracing::warn!(%requested_recv_buffer_size, "Failed to set recv buffer size: {e}");
        }

        #[cfg(any(target_os = "macos", target_os = "ios"))]
        self.flow_sockets
            .set_buffer_sizes(requested_send_buffer_size, requested_recv_buffer_size);

        let send_buffer_size = socket.send_buffer_size().unwrap_or_default();
        let recv_buffer_size = socket.recv_buffer_size().unwrap_or_default();

        tracing::debug!(%requested_send_buffer_size, %send_buffer_size, %requested_recv_buffer_size, %recv_buffer_size, port = %self.port, "UDP socket buffer sizes");
    }

    /// Sends a [`Transmit`] over the given socket, chunked to honor GSO limits.
    ///
    /// Connected sockets participate in Darwin's flow advisories: under congestion the kernel
    /// drops the datagram, returns `ENOBUFS` and fails all further sends instantly until the
    /// interface queue drains, which it signals via write-readiness. For those, we park until
    /// that signal instead of spinning.
    async fn send_transmit(
        &self,
        socket: &tokio::net::UdpSocket,
        state: &quinn_udp::UdpSocketState,
        transmit: &Transmit<'_>,
        connected: bool,
    ) -> Result<()> {
        let segment_size = transmit
            .segment_size
            .expect("`segment_size` must always be set");
        let src = transmit.src_ip;
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
            let chunk_size = self.calculate_chunk_size(state, segment_size, dst)?;

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
            tracing::trace!(target: "wire::net::send", ?src, %dst, ecn = ?chunk.ecn, num_packets = %(contents.len() / segment_size), %segment_size, %connected);

            let result = if connected {
                // Connected sockets never return `EWOULDBLOCK` on Darwin; issue the syscall
                // directly instead of going through tokio's (always-set) write-readiness.
                state.try_send(UdpSockRef::from(socket), &chunk)
            } else {
                socket
                    .async_io(Interest::WRITABLE, || {
                        state.try_send(UdpSockRef::from(socket), &chunk)
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
                #[cfg(any(target_os = "macos", target_os = "ios"))]
                Err(e)
                    if connected
                        && is_transient_send_error(&e)
                        && attempt < MAX_SEND_CAPACITY_WAITS =>
                {
                    wait_for_send_capacity(socket).await;
                    attempt += 1;
                }
                #[cfg(any(target_os = "macos", target_os = "ios"))]
                Err(e) if connected && is_icmp_unreachable(&e) => {
                    self.record_send_retries(attempt);

                    // The kernel received an ICMP error for this path; the error is one-shot.
                    // Drop the packet: either the path recovers or connlib migrates / times out.
                    tracing::debug!(%dst, "Dropping packet for unreachable destination: {e}");

                    return Ok(());
                }
                Err(e) if !connected && should_retry(&e, attempt) => {
                    spin_and_yield(attempt).await;
                    attempt += 1;
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
fn apply_buffer_size(
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

/// How many times we wait for send capacity on a flow socket before giving up on a batch.
///
/// Each wait is bounded by [`SEND_CAPACITY_WAIT`]; in the common (flow-advisory) case the
/// write-readiness wakeup arrives well before the timeout.
#[cfg(any(target_os = "macos", target_os = "ios"))]
const MAX_SEND_CAPACITY_WAITS: u32 = 8;

#[cfg(any(target_os = "macos", target_os = "ios"))]
const SEND_CAPACITY_WAIT: std::time::Duration = std::time::Duration::from_millis(10);

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
#[cfg(any(target_os = "macos", target_os = "ios"))]
async fn wait_for_send_capacity(socket: &tokio::net::UdpSocket) {
    let _ = socket.try_io(Interest::WRITABLE, || {
        Err::<(), io::Error>(io::ErrorKind::WouldBlock.into())
    });

    let _ = tokio::time::timeout(SEND_CAPACITY_WAIT, socket.writable()).await;
}

/// Whether a send may succeed if we try again after waiting for send capacity.
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn is_transient_send_error(e: &io::Error) -> bool {
    matches!(e.raw_os_error(), Some(libc::ENOBUFS | libc::EAGAIN))
}

/// Receives a batch of datagrams from the socket, ignoring ICMP errors.
///
/// Connected sockets surface (one-shot) ICMP errors on receive; they are not fatal.
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn recv_swallowing_icmp_errors(
    state: &quinn_udp::UdpSocketState,
    socket: &tokio::net::UdpSocket,
    bufs: &mut [IoSliceMut<'_>],
    meta: &mut [quinn_udp::RecvMeta],
) -> io::Result<usize> {
    loop {
        match state.recv(UdpSockRef::from(socket), bufs, meta) {
            Err(e) if is_icmp_unreachable(&e) => {
                tracing::trace!("Ignoring ICMP error on connected UDP socket: {e}");
                continue;
            }
            result => return result,
        }
    }
}

/// Only connected sockets receive ICMP errors; outside of Apple platforms we don't have any.
#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn recv_swallowing_icmp_errors(
    state: &quinn_udp::UdpSocketState,
    socket: &tokio::net::UdpSocket,
    bufs: &mut [IoSliceMut<'_>],
    meta: &mut [quinn_udp::RecvMeta],
) -> io::Result<usize> {
    state.recv(UdpSockRef::from(socket), bufs, meta)
}

/// Whether the error originates from an ICMP message for a connected socket's path.
#[cfg(any(target_os = "macos", target_os = "ios"))]
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
    // It's transient and clears off this thread (driver / NIC), and isn't observable
    // via write-readiness, so we retry rather than suspend.
    #[cfg(any(target_os = "macos", target_os = "ios"))]
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

/// An iterator that segments an array of buffers into individual datagrams.
///
/// This iterator is generic over its buffer type and the number of buffers to allow easier testing without a buffer pool.
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
pub struct DatagramSegmentIter<const N: usize = { quinn_udp::BATCH_SIZE }, B = Buffer<Vec<u8>>> {
    #[debug(skip)]
    buffers: [B; N],
    metas: [quinn_udp::RecvMeta; N],
    len: usize,

    port: u16,

    buf_index: usize,
    segment_index: usize,

    _total_bytes: usize,
    _num_packets: usize,
}

impl<B, const N: usize> DatagramSegmentIter<N, B> {
    pub(crate) fn new(
        buffers: [B; N],
        metas: [quinn_udp::RecvMeta; N],
        port: u16,
        len: usize,
    ) -> Self {
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
            len,
            port,
            buf_index: 0,
            segment_index: 0,
            _total_bytes: total_bytes,
            _num_packets: num_packets,
        }
    }
}

impl<B, const N: usize> LendingIterator for DatagramSegmentIter<N, B>
where
    B: Deref<Target = Vec<u8>> + 'static,
{
    type Item<'a> = DatagramIn<'a>;

    fn next(&mut self) -> Option<Self::Item<'_>> {
        loop {
            if self.buf_index >= N || self.buf_index >= self.len {
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

    #[derive(derive_more::Deref)]
    struct DummyBuffer(Vec<u8>);

    #[test]
    fn datagram_iter_segments_buffer_correctly() {
        let mut iter = DatagramSegmentIter::new(
            [
                DummyBuffer(b"foobar1foobar2foobar3foobar4foobar5foo                 ".to_vec()),
                DummyBuffer(b"baz1baz2baz3baz4baz5foo       ".to_vec()),
                DummyBuffer(b"".to_vec()),
            ],
            [
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
            ],
            0,
            3,
        );

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

    /// A datagram sent to a fresh destination must connect a flow socket,
    /// and the reply must arrive through it.
    #[tokio::test]
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    async fn sends_and_receives_via_flow_socket() {
        let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let peer_addr = peer.local_addr().unwrap();

        let socket = udp("127.0.0.1:0".parse().unwrap())
            .unwrap()
            .into_perf()
            .unwrap();

        let pool = BufferPool::<BytesMut>::new(2048, "test");

        socket
            .send(DatagramOut {
                src: None,
                dst: peer_addr,
                packet: pool.pull_initialised(b"hello"),
                segment_size: 5,
                ecn: Ecn::NonEct,
            })
            .await
            .unwrap();

        let mut buf = [0u8; 16];
        let (len, from) = peer.recv_from(&mut buf).await.unwrap();
        assert_eq!(&buf[..len], b"hello");

        // The reply matches the connected socket's 4-tuple exactly and must be delivered via it.
        peer.send_to(b"world", from).await.unwrap();

        let mut iter = socket.recv_from().await.unwrap();
        let datagram = iter.next().unwrap();

        assert_eq!(datagram.packet, b"world");
        assert_eq!(datagram.from, peer_addr);
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
    #[cfg(any(target_os = "macos", target_os = "ios"))]
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
