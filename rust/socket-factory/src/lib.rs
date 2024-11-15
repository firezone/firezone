use firezone_logging::std_dyn_err;
use std::collections::HashMap;
use std::fmt;
use std::{
    borrow::Cow,
    // collections::VecDeque,
    io::{self, IoSliceMut},
    net::{IpAddr, SocketAddr},
    slice,
    task::{ready, Context, Poll},
};

use std::any::Any;
use std::collections::hash_map::Entry;
use std::pin::Pin;
use tokio::io::Interest;

pub const MAX_GSO_SEGMENTS: usize = quinn_udp::BATCH_SIZE;

pub trait SocketFactory<S>: Fn(&SocketAddr) -> io::Result<S> + Send + Sync + 'static {}

impl<F, S> SocketFactory<S> for F where F: Fn(&SocketAddr) -> io::Result<S> + Send + Sync + 'static {}

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
    src_by_dst_cache: HashMap<IpAddr, IpAddr>,

    port: u16,
}

impl UdpSocket {
    fn new(inner: tokio::net::UdpSocket) -> io::Result<Self> {
        let port = inner.local_addr()?.port();

        Ok(UdpSocket {
            state: quinn_udp::UdpSocketState::new(quinn_udp::UdpSockRef::from(&inner))?,
            port,
            inner,
            source_ip_resolver: Box::new(|_| Ok(None)),
            src_by_dst_cache: Default::default(),
        })
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
}

/// An outbound UDP datagram.
pub struct DatagramOut<'a> {
    pub src: Option<SocketAddr>,
    pub dst: SocketAddr,
    pub packet: Cow<'a, [u8]>,
    pub segment_size: Option<usize>,
}

impl UdpSocket {
    pub fn poll_recv_from<'b>(
        &self,
        buffer: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<impl Iterator<Item = DatagramIn<'b>> + fmt::Debug>> {
        let Self {
            port, inner, state, ..
        } = self;

        let bufs = &mut [IoSliceMut::new(buffer)];
        let mut meta = quinn_udp::RecvMeta::default();

        loop {
            ready!(inner.poll_recv_ready(cx))?;

            if let Ok(len) = inner.try_io(Interest::READABLE, || {
                state.recv((&inner).into(), bufs, slice::from_mut(&mut meta))
            }) {
                debug_assert_eq!(len, 1);

                if meta.len == 0 {
                    continue;
                }

                let Some(local_ip) = meta.dst_ip else {
                    tracing::warn!("Skipping packet without local IP");
                    continue;
                };

                match meta.stride.cmp(&meta.len) {
                    std::cmp::Ordering::Equal | std::cmp::Ordering::Less => {}
                    std::cmp::Ordering::Greater => {
                        return Poll::Ready(Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            format!(
                                "stride ({}) is larger than buffer len ({})",
                                meta.stride, meta.len
                            ),
                        )))
                    }
                }

                let local = SocketAddr::new(local_ip, *port);

                let segment_size = meta.stride;
                let num_packets = meta.len / segment_size;
                let trailing_bytes = meta.len % segment_size;

                tracing::trace!(target: "wire::net::recv", src = %meta.addr, dst = %local, %num_packets, %segment_size, %trailing_bytes);

                let iter = buffer[..meta.len]
                    .chunks(meta.stride)
                    .map(move |packet| DatagramIn {
                        local,
                        from: meta.addr,
                        packet,
                    });

                return Poll::Ready(Ok(iter));
            }
        }
    }

    pub fn poll_send_ready(&self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.inner.poll_send_ready(cx)
    }

    pub fn send(&mut self, datagram: DatagramOut) -> io::Result<()> {
        let segment_size = datagram.segment_size.unwrap_or(datagram.packet.len());
        let num_packets = datagram.packet.len() / segment_size;

        tracing::trace!(target: "wire::net::send", src = ?datagram.src, dst = %datagram.dst, %num_packets, %segment_size);

        self.try_send(datagram)?;

        Ok(())
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
        mut self,
        dst: SocketAddr,
        payload: &[u8],
    ) -> io::Result<Vec<u8>> {
        let transmit = self
            .prepare_transmit(dst, None, payload, None)?
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

    fn try_send(&mut self, datagram: DatagramOut) -> io::Result<()> {
        let Some(transmit) = self.prepare_transmit(
            datagram.dst,
            datagram.src.map(|s| s.ip()),
            &datagram.packet,
            datagram.segment_size,
        )?
        else {
            return Ok(());
        };

        self.inner.try_io(Interest::WRITABLE, || {
            self.state.try_send((&self.inner).into(), &transmit)
        })
    }

    fn prepare_transmit<'a>(
        &mut self,
        dst: SocketAddr,
        src_ip: Option<IpAddr>,
        packet: &'a [u8],
        segment_size: Option<usize>,
    ) -> io::Result<Option<quinn_udp::Transmit<'a>>> {
        let src_ip = match src_ip {
            Some(src_ip) => Some(src_ip),
            None => match self.resolve_source_for(dst.ip()) {
                Ok(src_ip) => src_ip,
                Err(e) => {
                    tracing::trace!(
                        error = std_dyn_err(&e),
                        dst = %dst.ip(),
                        "No available interface for packet"
                    );
                    return Ok(None); // Not an error because we log it above already.
                }
            },
        };

        let transmit = quinn_udp::Transmit {
            destination: dst,
            ecn: None,
            contents: packet,
            segment_size,
            src_ip,
        };

        Ok(Some(transmit))
    }

    /// Attempt to resolve the source IP to use for sending to the given destination IP.
    fn resolve_source_for(&mut self, dst: IpAddr) -> std::io::Result<Option<IpAddr>> {
        let src = match self.src_by_dst_cache.entry(dst) {
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
