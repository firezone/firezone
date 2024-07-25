use std::{io, net::SocketAddr};

use socket2::SockAddr;

pub trait SocketFactory<S>: Fn(&SocketAddr) -> io::Result<S> + Send + Sync + 'static {}

impl<F, S> SocketFactory<S> for F where F: Fn(&SocketAddr) -> io::Result<S> + Send + Sync + 'static {}

pub fn tcp(addr: &SocketAddr) -> io::Result<tokio::net::TcpSocket> {
    let socket = match addr {
        SocketAddr::V4(_) => tokio::net::TcpSocket::new_v4()?,
        SocketAddr::V6(_) => tokio::net::TcpSocket::new_v6()?,
    };

    socket.set_nodelay(true)?;

    Ok(socket)
}
pub fn udp(addr: &SocketAddr) -> io::Result<tokio::net::UdpSocket> {
    let addr: SockAddr = (*addr).into();
    let socket = socket2::Socket::new(addr.domain(), socket2::Type::DGRAM, None)?;

    // Note: for AF_INET sockets IPV6_V6ONLY is not a valid flag
    if addr.is_ipv6() {
        socket.set_only_v6(true)?;
    }

    socket.set_nonblocking(true)?;
    socket.bind(&addr)?;

    std::net::UdpSocket::from(socket).try_into()
}
