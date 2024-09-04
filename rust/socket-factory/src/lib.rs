use std::collections::HashMap;
use std::{
    borrow::Cow,
    // collections::VecDeque,
    io::{self, IoSliceMut},
    net::{IpAddr, SocketAddr},
    slice,
    task::{ready, Context, Poll},
};

use socket2::SockAddr;
use std::collections::hash_map::Entry;
use tokio::io::Interest;

pub trait SocketFactory<S>: Fn(&SocketAddr) -> io::Result<S> + Send + Sync + 'static {}

impl<F, S> SocketFactory<S> for F where F: Fn(&SocketAddr) -> io::Result<S> + Send + Sync + 'static {}

pub fn tcp(addr: &SocketAddr) -> io::Result<TcpSocket> {
    let socket = match addr {
        SocketAddr::V4(_) => tokio::net::TcpSocket::new_v4()?,
        SocketAddr::V6(_) => tokio::net::TcpSocket::new_v6()?,
    };

    socket.set_nodelay(true)?;

    Ok(TcpSocket { inner: socket })
}

pub fn udp(addr: &SocketAddr) -> io::Result<UdpSocket> {
    let addr: SockAddr = (*addr).into();
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
}

impl TcpSocket {
    pub async fn connect(self, addr: SocketAddr) -> io::Result<tokio::net::TcpStream> {
        self.inner.connect(addr).await
    }

    pub fn bind(&self, addr: SocketAddr) -> io::Result<()> {
        self.inner.bind(addr)
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
}

impl UdpSocket {
    #[allow(clippy::type_complexity)]
    pub fn poll_recv_from<'b>(
        &self,
        buffer: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<impl Iterator<Item = DatagramIn<'b>>>> {
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

                let local = SocketAddr::new(local_ip, *port);

                let iter = buffer[..meta.len]
                    .chunks(meta.stride)
                    .map(move |packet| DatagramIn {
                        local,
                        from: meta.addr,
                        packet,
                    })
                    .inspect(|r| {
                        tracing::trace!(target: "wire::net::recv", src = %r.from, dst = %r.local, num_bytes = %r.packet.len());
                    });

                return Poll::Ready(Ok(iter));
            }
        }
    }

    pub fn poll_send_ready(&self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.inner.poll_send_ready(cx)
    }

    pub fn send(&mut self, datagram: DatagramOut) -> io::Result<()> {
        tracing::trace!(target: "wire::net::send", src = ?datagram.src, dst = %datagram.dst, num_bytes = %datagram.packet.len());

        self.try_send(&datagram)?;

        Ok(())
    }

    pub fn try_send(&mut self, transmit: &DatagramOut) -> io::Result<()> {
        let destination = transmit.dst;
        let src_ip = transmit.src.map(|s| s.ip());

        let src_ip = match src_ip {
            Some(src_ip) => Some(src_ip),
            None => match self.resolve_source_for(destination.ip()) {
                Ok(src_ip) => src_ip,
                Err(e) => {
                    tracing::trace!(
                        dst = %transmit.dst.ip(),
                        "No available interface for packet: {e}"
                    );
                    return Ok(());
                }
            },
        };

        let transmit = quinn_udp::Transmit {
            destination,
            ecn: None,
            contents: &transmit.packet,
            segment_size: None,
            src_ip,
        };

        self.inner.try_io(Interest::WRITABLE, || {
            self.state.send((&self.inner).into(), &transmit)
        })
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
