use bytes::Bytes;
use core::slice;
use quinn_udp::{RecvMeta, Transmit, UdpSockRef, UdpSocketState};
use socket2::{SockAddr, Type};
use std::{
    io::{self, IoSliceMut},
    net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    task::{ready, Context, Poll},
};
use tokio::{io::Interest, net::UdpSocket};

pub struct Socket<const N: usize> {
    state: UdpSocketState,
    port: u16,
    socket: UdpSocket,
    buffer: Box<[u8; N]>,
}

impl<const N: usize> Socket<N> {
    pub fn ip4() -> io::Result<Socket<N>> {
        let socket = make_socket(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0))?;
        let port = socket.local_addr()?.port();

        Ok(Socket {
            state: UdpSocketState::new(UdpSockRef::from(&socket))?,
            port,
            socket: tokio::net::UdpSocket::from_std(socket)?,
            buffer: Box::new([0u8; N]),
        })
    }

    pub fn ip6() -> io::Result<Socket<N>> {
        let socket = make_socket(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 0, 0, 0))?;
        let port = socket.local_addr()?.port();

        Ok(Socket {
            state: UdpSocketState::new(UdpSockRef::from(&socket))?,
            port,
            socket: tokio::net::UdpSocket::from_std(socket)?,
            buffer: Box::new([0u8; N]),
        })
    }

    #[allow(clippy::type_complexity)]
    pub fn poll_recv_from<'b>(
        &'b mut self,
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<Received<'b>>> {
        let Socket {
            port,
            socket,
            buffer,
            state,
        } = self;

        let bufs = &mut [IoSliceMut::new(buffer.as_mut())];
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

                return Poll::Ready(Ok(Received {
                    local,
                    from: meta.addr,
                    packet: &mut buffer[..meta.len],
                }));
            }
        }
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn try_send_to(
        &self,
        local: Option<SocketAddr>,
        dest: SocketAddr,
        buf: &[u8],
    ) -> io::Result<usize> {
        self.state.send(
            (&self.socket).into(),
            &[Transmit {
                destination: dest,
                ecn: None,
                contents: Bytes::copy_from_slice(buf),
                segment_size: None,
                src_ip: local.map(|s| s.ip()),
            }],
        )
    }
}

pub struct Received<'a> {
    pub local: SocketAddr,
    pub from: SocketAddr,
    pub packet: &'a [u8],
}

fn make_socket(addr: impl Into<SocketAddr>) -> io::Result<std::net::UdpSocket> {
    let addr: SockAddr = addr.into().into();
    let socket = socket2::Socket::new(addr.domain(), Type::DGRAM, None)?;
    socket.set_nonblocking(true)?;
    socket.bind(&addr)?;

    // TODO: for android protect file descriptor
    #[cfg(target_os = "linux")]
    socket.set_mark(crate::FIREZONE_MARK)?;

    // Note: for AF_INET sockets IPV6_V6ONLY is not a valid flag
    if addr.is_ipv6() {
        socket.set_only_v6(true)?;
    }

    Ok(socket.into())
}
