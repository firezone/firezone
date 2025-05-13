use anyhow::{Context as _, Result};
use bufferpool::{Buffer, BufferPool};
use bytes::{Buf as _, BytesMut};
use firezone_logging::err_with_src;
use gat_lending_iterator::LendingIterator;
use ip_packet::{Ecn, Ipv4Header, Ipv6Header, UdpHeader};
use opentelemetry::KeyValue;
use parking_lot::Mutex;
use quinn_udp::{EcnCodepoint, Transmit};
use std::collections::HashMap;
use std::io;
use std::io::IoSliceMut;
use std::ops::Deref;
use std::{
    net::{IpAddr, SocketAddr},
    task::{Context, Poll, ready},
};

use std::any::Any;
use std::collections::hash_map::Entry;
use std::pin::Pin;
use tokio::io::Interest;

pub trait SocketFactory<S>: Fn(&SocketAddr) -> io::Result<S> + Send + Sync + 'static {
    fn reset(&self);
}

pub const SEND_BUFFER_SIZE: usize = ONE_MB;
pub const RECV_BUFFER_SIZE: usize = 10 * ONE_MB;
const ONE_MB: usize = 1024 * 1024;

impl<F, S> SocketFactory<S> for F
where
    F: Fn(&SocketAddr) -> io::Result<S> + Send + Sync + 'static,
{
    fn reset(&self) {}
}

pub fn tcp(addr: &SocketAddr) -> io::Result<TcpSocket> {
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

pub fn udp(std_addr: &SocketAddr) -> io::Result<UdpSocket> {
    let addr = socket2::SockAddr::from(*std_addr);
    let socket = socket2::Socket::new(addr.domain(), socket2::Type::DGRAM, None)?;

    // Note: for AF_INET sockets IPV6_V6ONLY is not a valid flag
    if addr.is_ipv6() {
        socket.set_only_v6(true)?;
    }

    socket.set_nonblocking(true)?;
    socket.bind(&addr)?;

    let send_buf_size = socket.send_buffer_size()?;
    let recv_buf_size = socket.recv_buffer_size()?;

    tracing::trace!(addr = %std_addr, %send_buf_size, %recv_buf_size, "Created new UDP socket");

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
    state: quinn_udp::UdpSocketState,
    source_ip_resolver:
        Box<dyn Fn(IpAddr) -> std::io::Result<Option<IpAddr>> + Send + Sync + 'static>,

    /// A cache of source IPs by their destination IPs.
    src_by_dst_cache: Mutex<HashMap<IpAddr, IpAddr>>,

    /// A buffer pool for batches of incoming UDP packets.
    buffer_pool: BufferPool<Vec<u8>>,

    gro_batch_histogram: opentelemetry::metrics::Histogram<u64>,
    port: u16,
}

impl UdpSocket {
    fn new(inner: tokio::net::UdpSocket) -> io::Result<Self> {
        let socket_addr = inner.local_addr()?;
        let port = socket_addr.port();

        Ok(UdpSocket {
            state: quinn_udp::UdpSocketState::new(quinn_udp::UdpSockRef::from(&inner))?,
            port,
            inner,
            source_ip_resolver: Box::new(|_| Ok(None)),
            src_by_dst_cache: Default::default(),
            buffer_pool: BufferPool::new(
                u16::MAX as usize,
                match socket_addr.ip() {
                    IpAddr::V4(_) => "udp-socket-v4",
                    IpAddr::V6(_) => "udp-socket-v6",
                },
            ),
            gro_batch_histogram: opentelemetry::global::meter("connlib")
                .u64_histogram("system.network.packets.batch_count")
                .with_description(
                    "How many batches of packets we have processed in a single syscall.",
                )
                .with_unit("{batches}")
                .with_boundaries((1..32_u64).map(|i| i as f64).collect())
                .build(),
        })
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

        tracing::info!(%requested_send_buffer_size, %send_buffer_size, %requested_recv_buffer_size, %recv_buffer_size, port = %self.port, "Set UDP socket buffer sizes");

        Ok(())
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// Configures a new source IP resolver for this UDP socket.
    ///
    /// In case [`DatagramOut::src`] is [`None`], this function will be used to set a source IP given the destination IP of the datagram.
    /// The resulting IPs will be cached.
    /// To evict this cache, drop the [`UdpSocket`] and make a new one.
    ///
    /// Errors during resolution result in the packet being dropped.
    pub fn with_source_ip_resolver(
        mut self,
        resolver: Box<dyn Fn(IpAddr) -> std::io::Result<Option<IpAddr>> + Send + Sync + 'static>,
    ) -> Self {
        self.source_ip_resolver = resolver;
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
    pub segment_size: Option<usize>,
    pub ecn: Ecn,
}

impl UdpSocket {
    pub async fn recv_from(&self) -> Result<DatagramSegmentIter> {
        std::future::poll_fn(|cx| self.poll_recv_from(cx)).await
    }

    fn poll_recv_from(&self, cx: &mut Context<'_>) -> Poll<Result<DatagramSegmentIter>> {
        let Self {
            port, inner, state, ..
        } = self;

        // Stack-allocate arrays for buffers and meta. The size is implied from the const-generic default on `DatagramSegmentIter`.
        let mut bufs = std::array::from_fn(|_| self.buffer_pool.pull());
        let mut meta = std::array::from_fn(|_| quinn_udp::RecvMeta::default());

        loop {
            ready!(inner.poll_recv_ready(cx)).context("Failed to poll UDP socket for readiness")?;

            let recv = || {
                // Fancy std-functions ahead: `each_mut` transforms our array into an array of references to our items and `map` allows us to create an `IoSliceMut` out of each element.
                // `state.recv` requires us to pass `IoSliceMut` but later on, we need the original buffer again because `DatagramSegmentIter` needs to own them.
                // That is why we cannot just create an `IoSliceMut` to begin with.
                let mut bufs = bufs.each_mut().map(|b| IoSliceMut::new(b));
                let socket = (&inner).into();

                state.recv(socket, &mut bufs, &mut meta)
            };

            if let Ok(len) = inner.try_io(Interest::READABLE, recv) {
                self.gro_batch_histogram.record(
                    len as u64,
                    &[
                        KeyValue::new("network.transport", "udp"),
                        KeyValue::new("network.io.direction", "receive"),
                    ],
                );

                return Poll::Ready(Ok(DatagramSegmentIter::new(bufs, meta, *port, len)));
            }
        }
    }

    pub fn poll_send_ready(&self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.inner.poll_send_ready(cx)
    }

    pub async fn send(&self, datagram: DatagramOut) -> Result<()> {
        let Some(transmit) = self.prepare_transmit(
            datagram.dst,
            datagram.src.map(|s| s.ip()),
            datagram.packet.chunk(),
            datagram.segment_size,
            datagram.ecn,
        )?
        else {
            return Ok(());
        };

        let dst = datagram.dst;

        match transmit.segment_size {
            Some(segment_size) => {
                let chunk_size = self.calculate_chunk_size(segment_size, transmit.destination);
                let num_batches = transmit.contents.len() / chunk_size;

                for (idx, chunk) in transmit
                    .contents
                    .chunks(chunk_size)
                    .map(|contents| Transmit {
                        destination: transmit.destination,
                        ecn: transmit.ecn,
                        contents,
                        segment_size: Some(segment_size),
                        src_ip: transmit.src_ip,
                    })
                    .enumerate()
                {
                    let num_bytes = chunk.contents.len();
                    let num_packets = num_bytes / segment_size;
                    let batch_num = idx + 1;

                    tracing::trace!(target: "wire::net::send", src = ?datagram.src, %dst, ecn = ?chunk.ecn, %num_packets, %segment_size);

                    self.inner
                        .async_io(Interest::WRITABLE, || {
                            self.state.try_send((&self.inner).into(), &chunk)
                        })
                        .await
                        .with_context(|| format!("Failed to send datagram-batch {batch_num}/{num_batches} with segment_size {segment_size} and total length {num_bytes} to {dst}"))?;
                }
            }
            None => {
                let num_bytes = transmit.contents.len();

                tracing::trace!(target: "wire::net::send", src = ?datagram.src, %dst, ecn = ?transmit.ecn, %num_bytes);

                self.inner
                    .async_io(Interest::WRITABLE, || {
                        self.state.try_send((&self.inner).into(), &transmit)
                    })
                    .await
                    .with_context(|| format!("Failed to send single-datagram to {dst}"))?;
            }
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

    /// Performs a single request-response handshake with the specified destination socket address.
    ///
    /// This consumes `self` because we want to enforce that we only receive a single message on this socket.
    /// UDP is stateless and therefore, anybody can just send a packet to our socket.
    ///
    /// To simulate a handshake, we therefore only wait for a single message arriving on this socket,
    /// after that, we discard it, freeing up the used source port.
    ///
    /// This is similar to the `connect` functionality but that one doesn't seem to work reliably in a cross-platform way.
    ///
    /// TODO: Should we make a type-safe API to ensure only one "mode" of the socket can be used?
    pub async fn handshake<const BUF_SIZE: usize>(
        self,
        dst: SocketAddr,
        payload: &[u8],
    ) -> io::Result<Vec<u8>> {
        let transmit = self
            .prepare_transmit(dst, None, payload, None, Ecn::NonEct)?
            .ok_or_else(|| io::Error::other("Failed to prepare `Transmit`"))?;

        self.inner
            .async_io(Interest::WRITABLE, || {
                self.state.try_send((&self.inner).into(), &transmit)
            })
            .await?;

        let mut buffer = vec![0u8; BUF_SIZE];

        let (num_received, sender) = self.inner.recv_from(&mut buffer).await?;

        if sender != dst {
            return Err(io::Error::other(format!(
                "Unexpected reply source: {sender}; expected: {dst}"
            )));
        }

        buffer.truncate(num_received);

        Ok(buffer)
    }

    fn prepare_transmit<'a>(
        &self,
        dst: SocketAddr,
        src_ip: Option<IpAddr>,
        packet: &'a [u8],
        segment_size: Option<usize>,
        ecn: Ecn,
    ) -> io::Result<Option<quinn_udp::Transmit<'a>>> {
        let src_ip = match src_ip {
            Some(src_ip) => Some(src_ip),
            None => match self.resolve_source_for(dst.ip()) {
                Ok(src_ip) => src_ip,
                Err(e) => {
                    tracing::trace!(
                        dst = %dst.ip(),
                        "No available interface for packet: {}", err_with_src(&e)
                    );
                    return Ok(None); // Not an error because we log it above already.
                }
            },
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
            segment_size,
            src_ip,
        };

        Ok(Some(transmit))
    }

    /// Attempt to resolve the source IP to use for sending to the given destination IP.
    fn resolve_source_for(&self, dst: IpAddr) -> std::io::Result<Option<IpAddr>> {
        let src = match self.src_by_dst_cache.lock().entry(dst) {
            Entry::Occupied(occ) => *occ.get(),
            Entry::Vacant(vac) => {
                // Caching errors could be a good idea to not incur in multiple calls for the resolver which can be costly
                // For some cases like hosts ipv4-only stack trying to send ipv6 packets this can happen quite often but doing this is also a risk
                // that in case that the adapter for some reason is temporarily unavailable it'd prevent the system from recovery.
                let Some(src) = (self.source_ip_resolver)(dst)? else {
                    return Ok(None);
                };
                *vac.insert(src)
            }
        };

        Ok(Some(src))
    }
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

    total_bytes: usize,
    num_packets: usize,
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
            total_bytes,
            num_packets,
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

            tracing::trace!(target: "wire::net::recv", num_p = %self.num_packets, tot_b = %self.total_bytes, src = %meta.addr, dst = %local, ecn = ?meta.ecn, len = %segment_size);

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
    use std::net::Ipv4Addr;

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
}
