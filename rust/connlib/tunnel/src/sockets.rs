use core::slice;
use quinn_udp::{RecvMeta, UdpSockRef, UdpSocketState};
use socket2::{SockAddr, Type};
use std::{
    io::{self, IoSliceMut},
    net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    task::{ready, Context, Poll},
};
use tokio::{io::Interest, net::UdpSocket};

use crate::Result;

pub struct Sockets {
    socket_v4: Option<Socket>,
    socket_v6: Option<Socket>,

    #[cfg(unix)]
    protect: Box<dyn Fn(std::os::fd::RawFd) -> io::Result<()> + Send + 'static>,
}

impl Default for Sockets {
    fn default() -> Self {
        Self::new()
    }
}

impl Sockets {
    #[cfg(unix)]
    pub fn with_protect(
        protect: impl Fn(std::os::fd::RawFd) -> io::Result<()> + Send + 'static,
    ) -> Self {
        Self {
            socket_v4: None,
            socket_v6: None,
            #[cfg(unix)]
            protect: Box::new(protect),
        }
    }

    pub fn new() -> Self {
        Self {
            socket_v4: None,
            socket_v6: None,
            #[cfg(unix)]
            protect: Box::new(|_| Ok(())),
        }
    }

    pub fn can_handle(&self, addr: &SocketAddr) -> bool {
        match addr {
            SocketAddr::V4(_) => self.socket_v4.is_some(),
            SocketAddr::V6(_) => self.socket_v6.is_some(),
        }
    }

    pub fn rebind(&mut self) -> io::Result<()> {
        let socket_v4 = Socket::ip4();
        let socket_v6 = Socket::ip6();

        match (socket_v4.as_ref(), socket_v6.as_ref()) {
            (Err(e), Ok(_)) => {
                tracing::warn!("Failed to bind IPv4 socket: {e}");
            }
            (Ok(_), Err(e)) => {
                tracing::warn!("Failed to bind IPv6 socket: {e}");
            }
            (Err(e4), Err(e6)) => {
                tracing::error!("Failed to bind IPv4 socket: {e4}");
                tracing::error!("Failed to bind IPv6 socket: {e6}");

                return Err(io::Error::new(
                    io::ErrorKind::AddrNotAvailable,
                    "Unable to bind to interfaces",
                ));
            }
            _ => (),
        }

        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;

            if let Ok(fd) = socket_v4.as_ref().map(|s| s.socket.as_raw_fd()) {
                (self.protect)(fd)?;
            }

            if let Ok(fd) = socket_v6.as_ref().map(|s| s.socket.as_raw_fd()) {
                (self.protect)(fd)?;
            }
        }

        self.socket_v4 = socket_v4.ok();
        self.socket_v6 = socket_v6.ok();

        Ok(())
    }

    /// Flushes all buffered data on the sockets.
    ///
    /// Returns `Ready` if the socket is able to accept more data.
    pub fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if let Some(socket) = self.socket_v4.as_mut() {
            ready!(socket.poll_flush(cx))?;
        }

        if let Some(socket) = self.socket_v6.as_mut() {
            ready!(socket.poll_flush(cx))?;
        }

        Poll::Ready(Ok(()))
    }

    pub fn try_send(&mut self, transmit: quinn_udp::Transmit) -> io::Result<()> {
        match transmit.destination {
            SocketAddr::V4(dst) => {
                let socket = self.socket_v4.as_mut().ok_or(io::Error::new(
                    io::ErrorKind::NotConnected,
                    format!("failed send packet to {dst}: no IPv4 socket"),
                ))?;
                socket.send(transmit);
            }
            SocketAddr::V6(dst) => {
                let socket = self.socket_v6.as_mut().ok_or(io::Error::new(
                    io::ErrorKind::NotConnected,
                    format!("failed send packet to {dst}: no IPv6 socket"),
                ))?;
                socket.send(transmit);
            }
        }

        Ok(())
    }

    pub fn poll_recv_from<'b>(
        &self,
        ip4_buffer: &'b mut [u8],
        ip6_buffer: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<impl Iterator<Item = Received<'b>>>> {
        let mut iter = PacketIter::new();

        if let Some(Poll::Ready(packets)) = self
            .socket_v4
            .as_ref()
            .map(|s| s.poll_recv_from(ip4_buffer, cx))
        {
            iter.ip4 = Some(packets?);
        }

        if let Some(Poll::Ready(packets)) = self
            .socket_v6
            .as_ref()
            .map(|s| s.poll_recv_from(ip6_buffer, cx))
        {
            iter.ip6 = Some(packets?);
        }

        if iter.is_empty() {
            return Poll::Pending;
        }

        Poll::Ready(Ok(iter))
    }
}

struct PacketIter<T4, T6> {
    ip4: Option<T4>,
    ip6: Option<T6>,
}

impl<T4, T6> PacketIter<T4, T6> {
    fn new() -> Self {
        Self {
            ip4: None,
            ip6: None,
        }
    }

    fn is_empty(&self) -> bool {
        self.ip4.is_none() && self.ip6.is_none()
    }
}

impl<'a, T4, T6> Iterator for PacketIter<T4, T6>
where
    T4: Iterator<Item = Received<'a>>,
    T6: Iterator<Item = Received<'a>>,
{
    type Item = Received<'a>;

    fn next(&mut self) -> Option<Self::Item> {
        if let Some(packet) = self.ip4.as_mut().and_then(|i| i.next()) {
            return Some(packet);
        }

        if let Some(packet) = self.ip6.as_mut().and_then(|i| i.next()) {
            return Some(packet);
        }

        None
    }
}

pub struct Received<'a> {
    pub local: SocketAddr,
    pub from: SocketAddr,
    pub packet: &'a [u8],
}

struct Socket {
    state: UdpSocketState,
    port: u16,
    socket: UdpSocket,

    buffered_transmits: Vec<quinn_udp::Transmit>,
}

impl Socket {
    fn ip4() -> Result<Socket> {
        let socket = make_socket(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0))?;
        let port = socket.local_addr()?.port();

        Ok(Socket {
            state: UdpSocketState::new(UdpSockRef::from(&socket))?,
            port,
            socket: tokio::net::UdpSocket::from_std(socket)?,
            buffered_transmits: Vec::new(),
        })
    }

    fn ip6() -> Result<Socket> {
        let socket = make_socket(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 0, 0, 0))?;
        let port = socket.local_addr()?.port();

        Ok(Socket {
            state: UdpSocketState::new(UdpSockRef::from(&socket))?,
            port,
            socket: tokio::net::UdpSocket::from_std(socket)?,
            buffered_transmits: Vec::new(),
        })
    }

    #[allow(clippy::type_complexity)]
    fn poll_recv_from<'b>(
        &self,
        buffer: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<impl Iterator<Item = Received<'b>>>> {
        let Socket {
            port,
            socket,
            state,
            ..
        } = self;

        let bufs = &mut [IoSliceMut::new(buffer)];
        let mut meta = RecvMeta::default();

        loop {
            ready!(socket.poll_recv_ready(cx))?;

            if let Ok(len) = socket.try_io(Interest::READABLE, || {
                state.recv((&socket).into(), bufs, slice::from_mut(&mut meta))
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
                    .map(move |packet| Received {
                        local,
                        from: meta.addr,
                        packet,
                    })
                    .inspect(|r| {
                        tracing::trace!(target: "wire", from = "network", src = %r.from, dst = %r.local, num_bytes = %r.packet.len());
                    });

                return Poll::Ready(Ok(iter));
            }
        }
    }

    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        loop {
            match self.socket.try_io(Interest::WRITABLE, || {
                self.state
                    .send((&self.socket).into(), &self.buffered_transmits)
            }) {
                Ok(0) => break,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Poll::Ready(Err(e)),

                Ok(num_sent) => {
                    self.buffered_transmits.drain(..num_sent);

                    // I am not sure if we'd ever send less than what is in `buffered_transmits`.
                    // loop once more to be sure we `break` on either an empty buffer or on `WouldBlock`.
                }
            };
        }

        // Ensure we are ready to send more data.
        ready!(self.socket.poll_send_ready(cx)?);

        assert!(
            self.buffered_transmits.is_empty(),
            "buffer must be empty if we are ready to send more data"
        );

        Poll::Ready(Ok(()))
    }

    fn send(&mut self, transmit: quinn_udp::Transmit) {
        tracing::trace!(target: "wire", to = "network", src = ?transmit.src_ip, dst = %transmit.destination, num_bytes = %transmit.contents.len());

        self.buffered_transmits.push(transmit);

        debug_assert!(
            self.buffered_transmits.len() < 10_000,
            "We are not flushing the packets for some reason"
        );
    }
}

fn make_socket(addr: impl Into<SocketAddr>) -> Result<std::net::UdpSocket> {
    let addr: SockAddr = addr.into().into();
    let socket = socket2::Socket::new(addr.domain(), Type::DGRAM, None)?;

    #[cfg(target_os = "linux")]
    {
        socket.set_mark(crate::FIREZONE_MARK)?;
    }

    // Set socket buffer size to 8MB
    socket.set_send_buffer_size(8 * 1024 * 1024)?;
    socket.set_recv_buffer_size(8 * 1024 * 1024)?;

    // Note: for AF_INET sockets IPV6_V6ONLY is not a valid flag
    if addr.is_ipv6() {
        socket.set_only_v6(true)?;
    }

    socket.set_nonblocking(true)?;
    socket.bind(&addr)?;

    Ok(socket.into())
}
