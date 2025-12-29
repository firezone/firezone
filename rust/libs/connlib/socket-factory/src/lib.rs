use anyhow::{Context as _, ErrorExt, Result};
use bufferpool::{Buffer, BufferPool};
use bytes::{Buf as _, BytesMut};
use gat_lending_iterator::LendingIterator;
use ip_packet::{Ecn, Ipv4Header, Ipv6Header, UdpHeader};
use opentelemetry::KeyValue;
use quinn_udp::{EcnCodepoint, Transmit, UdpSockRef};
use std::io;
use std::io::IoSliceMut;
use std::ops::Deref;
use std::time::Duration;
use std::{
    net::{IpAddr, SocketAddr},
    task::{Context, Poll},
};

use std::any::Any;
use std::pin::Pin;
use tokio::io::Interest;

pub trait SocketFactory<S>: Send + Sync + 'static {
    fn bind(&self, local: SocketAddr) -> io::Result<S>;
    fn reset(&self);
}

pub const SEND_BUFFER_SIZE: usize = 16 * ONE_MB;
pub const RECV_BUFFER_SIZE: usize = 128 * ONE_MB;
const ONE_MB: usize = 1024 * 1024;

/// How many times we at most try to re-send a packet if we encounter ENOBUFS.
#[cfg(any(target_os = "macos", target_os = "ios", test))]
const MAX_ENOBUFS_RETRIES: u32 = 24;

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

/// A UDP socket with performance optimisations for fast send & receive.
pub struct PerfUdpSocket {
    inner: tokio::net::UdpSocket,
    state: quinn_udp::UdpSocketState,

    /// A buffer pool for batches of incoming UDP packets.
    buffer_pool: BufferPool<Vec<u8>>,

    batch_histogram: opentelemetry::metrics::Histogram<u64>,
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

        Ok(PerfUdpSocket {
            inner: self.inner,
            state: quinn_state,
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
            source_ip_resolver: self.source_ip_resolver,
            port: self.port,
        })
    }

    pub fn port(&self) -> u16 {
        self.port
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
    pub async fn recv_from(&self) -> Result<DatagramSegmentIter> {
        // Stack-allocate arrays for buffers and meta. The size is implied from the const-generic default on `DatagramSegmentIter`.
        let mut bufs = std::array::from_fn(|_| self.buffer_pool.pull());
        let mut meta = std::array::from_fn(|_| quinn_udp::RecvMeta::default());

        let recv = || {
            // Fancy std-functions ahead: `each_mut` transforms our array into an array of references to our items and `map` allows us to create an `IoSliceMut` out of each element.
            // `state.recv` requires us to pass `IoSliceMut` but later on, we need the original buffer again because `DatagramSegmentIter` needs to own them.
            // That is why we cannot just create an `IoSliceMut` to begin with.
            let mut bufs = bufs.each_mut().map(|b| IoSliceMut::new(b));

            self.state
                .recv(UdpSockRef::from(&self.inner), &mut bufs, &mut meta)
        };

        let len = self
            .inner
            .async_io(Interest::READABLE, recv)
            .await
            .context("Failed to read from socket")?;

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

        let mut attempt = 0;

        loop {
            match self.send_transmit(&transmit).await {
                Ok(()) => return Ok(()),
                Err(e) => {
                    let backoff = backoff(&e, attempt).ok_or(e)?; // Attempt to get a backoff value or otherwise bail with error.

                    tracing::debug!(?backoff, dst = %datagram.dst, len = %datagram.packet.len(), "Retrying packet");

                    tokio::time::sleep(backoff).await;
                }
            }

            attempt += 1;
        }
    }

    pub fn set_buffer_sizes(
        &mut self,
        requested_send_buffer_size: usize,
        requested_recv_buffer_size: usize,
    ) -> io::Result<()> {
        let socket = socket2::SockRef::from(&self.inner);

        socket.set_send_buffer_size(requested_send_buffer_size)?;
        socket.set_recv_buffer_size(requested_recv_buffer_size)?;

        let send_buffer_size = socket.send_buffer_size()?;
        let recv_buffer_size = socket.recv_buffer_size()?;

        tracing::debug!(%requested_send_buffer_size, %send_buffer_size, %requested_recv_buffer_size, %recv_buffer_size, port = %self.port, "Set UDP socket buffer sizes");

        Ok(())
    }

    async fn send_transmit(&self, transmit: &Transmit<'_>) -> Result<()> {
        let segment_size = transmit
            .segment_size
            .expect("`segment_size` must always be set");
        let src = transmit.src_ip;
        let dst = transmit.destination;

        let chunk_size = self.calculate_chunk_size(segment_size, dst);
        let num_batches = transmit.contents.len() / chunk_size;

        for (idx, chunk) in transmit
            .contents
            .chunks(chunk_size)
            .map(|contents| Transmit {
                destination: dst,
                ecn: transmit.ecn,
                contents,
                segment_size: Some(segment_size),
                src_ip: src,
            })
            .enumerate()
        {
            let num_bytes = chunk.contents.len();
            let batch_num = idx + 1;

            #[cfg(debug_assertions)]
            tracing::trace!(target: "wire::net::send", ?src, %dst, ecn = ?chunk.ecn, num_packets = %(num_bytes / segment_size), %segment_size);

            let batch_size =
                chunk.contents.len() / chunk.segment_size.unwrap_or(chunk.contents.len());

            self.batch_histogram.record(
                batch_size as u64,
                &[
                    KeyValue::new("network.transport", "udp"),
                    KeyValue::new("network.io.direction", "transmit"),
                ],
            );

            self.inner
                .async_io(Interest::WRITABLE, || self.state.try_send((&self.inner).into(), &chunk))
                .await
                .with_context(|| format!("Failed to send datagram-batch {batch_num}/{num_batches} with segment_size {segment_size} and total length {num_bytes} to {dst}"))?;
        }

        Ok(())
    }

    /// Calculate the chunk size for a given segment size.
    ///
    /// At most, an IP packet can 65535 (`u16::MAX`) bytes.
    /// To know the maximum size we can pass as the UDP payload, we need to subtract the IP and UDP header length as overhead.
    ///
    /// In case GSO is not supported at all by the kernel, `quinn_udp` will detect this and set `max_gso_segments` to 1.
    /// We need to honor both of these constraints when calculating the chunk size.
    fn calculate_chunk_size(&self, segment_size: usize, dst: SocketAddr) -> usize {
        let header_overhead = match dst {
            SocketAddr::V4(_) => Ipv4Header::MAX_LEN + UdpHeader::LEN,
            SocketAddr::V6(_) => Ipv6Header::LEN + UdpHeader::LEN,
        };

        let max_segments_by_config = self.state.max_gso_segments();
        let max_segments_by_size = (u16::MAX as usize - header_overhead) / segment_size;

        let max_segments = std::cmp::min(max_segments_by_config, max_segments_by_size);

        segment_size * max_segments
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

#[cfg_attr(
    not(any(
        target_os = "linux",
        target_os = "android",
        target_os = "macos",
        target_os = "ios"
    )),
    expect(unused_variables, reason = "No backoff strategy for other platforms")
)]
fn backoff(e: &anyhow::Error, attempts: u32) -> Option<Duration> {
    let raw_os_error = e.any_downcast_ref::<io::Error>()?.raw_os_error()?;

    // On Linux and Android, we retry sending once for os error 5.
    //
    // quinn-udp disables GSO for those but cannot automatically re-send them because we need to split the datagram differently.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    if raw_os_error == libc::EIO && attempts < 1 {
        return Some(Duration::ZERO);
    }

    // On MacOS, the kernel may return ENOBUFS if the buffer fills up.
    //
    // Ideally, we would be able to suspend here but MacOS doesn't support that.
    // Thus, we do the next best thing and retry.
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    if raw_os_error == libc::ENOBUFS && attempts < MAX_ENOBUFS_RETRIES {
        return Some(exp_delay(attempts));
    }

    None
}

#[cfg(any(target_os = "macos", target_os = "ios", test))]
fn exp_delay(attempts: u32) -> Duration {
    Duration::from_nanos(2_u64.pow(attempts))
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
    fn new(buffers: [B; N], metas: [quinn_udp::RecvMeta; N], port: u16, len: usize) -> Self {
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
                quinn_udp::RecvMeta {
                    addr: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
                    dst_ip: Some(IpAddr::V4(Ipv4Addr::LOCALHOST)),
                    stride: 7,
                    len: 38,
                    ecn: None,
                },
                quinn_udp::RecvMeta {
                    addr: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
                    dst_ip: Some(IpAddr::V4(Ipv4Addr::LOCALHOST)),
                    stride: 4,
                    len: 23,
                    ecn: None,
                },
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

    #[test]
    fn max_enobufs_delay() {
        assert_eq!(
            exp_delay(MAX_ENOBUFS_RETRIES),
            Duration::from_nanos(16_777_216) // ~16ms
        )
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn immediate_retry_of_os_error_5() {
        let err = anyhow::Error::new(io::Error::from_raw_os_error(libc::EIO));

        let backoff = backoff(&err, 0);

        assert_eq!(backoff.unwrap(), Duration::ZERO);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn only_one_retry_of_os_error_5() {
        let err = anyhow::Error::new(io::Error::from_raw_os_error(libc::EIO));

        let backoff = backoff(&err, 1);

        assert!(backoff.is_none());
    }

    #[test]
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    fn at_most_24_retries_of_enobufs() {
        let err = anyhow::Error::new(io::Error::from_raw_os_error(libc::ENOBUFS));

        assert!(backoff(&err, 23).is_some());
        assert!(backoff(&err, 24).is_none());
    }
}
