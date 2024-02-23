use bytes::Bytes;
use core::slice;
use quinn_udp::{RecvMeta, UdpSockRef, UdpSocketState};
use socket2::{SockAddr, Type};
use std::{
    io::{self, IoSliceMut},
    net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    task::{ready, Context, Poll},
};
use tokio::{io::Interest, net::UdpSocket};

use crate::{Error, Result, MAX_UDP_SIZE};
use snownet::Transmit;

pub struct Sockets {
    socket_v4: Option<Socket<MAX_UDP_SIZE>>,
    socket_v6: Option<Socket<MAX_UDP_SIZE>>,
}

impl Sockets {
    pub fn new() -> crate::Result<Self> {
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

                return Err(Error::Io(io::Error::new(
                    io::ErrorKind::AddrNotAvailable,
                    "Unable to bind to interfaces",
                )));
            }
            _ => (),
        }

        Ok(Self {
            socket_v4: socket_v4.ok(),
            socket_v6: socket_v6.ok(),
        })
    }

    pub fn can_handle(&self, addr: &SocketAddr) -> bool {
        match addr {
            SocketAddr::V4(_) => self.socket_v4.is_some(),
            SocketAddr::V6(_) => self.socket_v6.is_some(),
        }
    }

    #[cfg(target_os = "android")]
    pub fn ip4_socket_fd(&self) -> Option<std::os::fd::RawFd> {
        use std::os::fd::AsRawFd;

        self.socket_v4.as_ref().map(|s| s.socket.as_raw_fd())
    }

    #[cfg(target_os = "android")]
    pub fn ip6_socket_fd(&self) -> Option<std::os::fd::RawFd> {
        use std::os::fd::AsRawFd;

        self.socket_v6.as_ref().map(|s| s.socket.as_raw_fd())
    }

    pub fn poll_send_ready(&self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if let Some(socket) = self.socket_v4.as_ref() {
            ready!(socket.poll_send_ready(cx))?;
        }

        if let Some(socket) = self.socket_v6.as_ref() {
            ready!(socket.poll_send_ready(cx))?;
        }

        Poll::Ready(Ok(()))
    }

    pub fn send(&self, transmit: &Transmit) {
        if let Err(e) = self.try_send(transmit) {
            tracing::warn!(dest = %transmit.dst, "Failed to send packet: {e}")
        }
    }

    pub fn try_send(&self, transmit: &Transmit) -> Result<usize> {
        tracing::trace!(target: "wire", action = "write", to = %transmit.dst, src = ?transmit.src, bytes = %transmit.payload.len());

        match transmit.dst {
            SocketAddr::V4(_) => {
                let socket = self.socket_v4.as_ref().ok_or(Error::NoIpv4)?;
                Ok(socket.try_send_to(transmit.src, transmit.dst, &transmit.payload)?)
            }
            SocketAddr::V6(_) => {
                let socket = self.socket_v6.as_ref().ok_or(Error::NoIpv6)?;
                Ok(socket.try_send_to(transmit.src, transmit.dst, &transmit.payload)?)
            }
        }
    }

    pub fn poll_recv_from<'a>(
        &self,
        buffer: &'a mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<impl Iterator<Item = Received<'a>>> {
        let middle = buffer.len() / 2;

        let (ip4_buffer, ip6_buffer) = buffer.split_at_mut(middle);

        let mut ret = PacketsIter {
            ip4: None,
            ip6: None,
        };

        if let Some(Poll::Ready(Ok(packets))) = self
            .socket_v4
            .as_ref()
            .map(|s| s.poll_recv_from(ip4_buffer, cx))
        {
            ret.ip4 = Some(packets);
        }

        if let Some(Poll::Ready(Ok(packets))) = self
            .socket_v6
            .as_ref()
            .map(|s| s.poll_recv_from(ip6_buffer, cx))
        {
            ret.ip6 = Some(packets);
        }

        if ret.ip4.is_none() && ret.ip6.is_none() {
            return Poll::Pending;
        }

        Poll::Ready(ret)
    }
}

struct PacketsIter<T1, T2> {
    ip4: Option<T1>,
    ip6: Option<T2>,
}

impl<'a, T1, T2> Iterator for PacketsIter<T1, T2>
where
    T1: Iterator<Item = Received<'a>>,
    T2: Iterator<Item = Received<'a>>,
{
    type Item = Received<'a>;

    fn next(&mut self) -> Option<Self::Item> {
        if let Some(next) = self.ip4.as_mut().and_then(|i| i.next()) {
            return Some(next);
        }

        if let Some(next) = self.ip6.as_mut().and_then(|i| i.next()) {
            return Some(next);
        }

        None
    }
}

pub struct Received<'a> {
    pub local: SocketAddr,
    pub from: SocketAddr,
    pub packet: &'a [u8],
}

struct Socket<const N: usize> {
    state: UdpSocketState,
    port: u16,
    socket: UdpSocket,
}

impl<const N: usize> Socket<N> {
    fn ip4() -> Result<Socket<N>> {
        let socket = make_socket(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0))?;
        let port = socket.local_addr()?.port();

        Ok(Socket {
            state: UdpSocketState::new(UdpSockRef::from(&socket))?,
            port,
            socket: tokio::net::UdpSocket::from_std(socket)?,
        })
    }

    fn ip6() -> Result<Socket<N>> {
        let socket = make_socket(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 0, 0, 0))?;
        let port = socket.local_addr()?.port();

        Ok(Socket {
            state: UdpSocketState::new(UdpSockRef::from(&socket))?,
            port,
            socket: tokio::net::UdpSocket::from_std(socket)?,
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

                return Poll::Ready(Ok(buffer[..meta.len].chunks(meta.stride).map(
                    move |packet| Received {
                        local,
                        from: meta.addr,
                        packet,
                    },
                )));
            }
        }
    }

    fn poll_send_ready(&self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.socket.poll_send_ready(cx)
    }

    fn try_send_to(
        &self,
        local: Option<SocketAddr>,
        dest: SocketAddr,
        buf: &[u8],
    ) -> io::Result<usize> {
        self.state.send(
            (&self.socket).into(),
            &[quinn_udp::Transmit {
                destination: dest,
                ecn: None,
                contents: Bytes::copy_from_slice(buf),
                segment_size: None,
                src_ip: local.map(|s| s.ip()),
            }],
        )
    }
}

fn make_socket(addr: impl Into<SocketAddr>) -> Result<std::net::UdpSocket> {
    let addr: SockAddr = addr.into().into();
    let socket = socket2::Socket::new(addr.domain(), Type::DGRAM, None)?;

    #[cfg(target_os = "linux")]
    {
        socket.set_mark(crate::FIREZONE_MARK)?;
    }

    // Note: for AF_INET sockets IPV6_V6ONLY is not a valid flag
    if addr.is_ipv6() {
        socket.set_only_v6(true)?;
    }

    socket.set_nonblocking(true)?;
    socket.bind(&addr)?;

    Ok(socket.into())
}
