use std::{io, net::SocketAddr};

use crate::FIREZONE_MARK;
use nix::sys::socket::{setsockopt, sockopt};
use socket_factory::{TcpSocket, UdpSocket};

pub fn tcp_socket_factory(socket_addr: &SocketAddr) -> io::Result<TcpSocket> {
    let socket = socket_factory::tcp(socket_addr)?;
    setsockopt(&socket, sockopt::Mark, &FIREZONE_MARK)?;
    Ok(socket)
}

pub fn udp_socket_factory(socket_addr: &SocketAddr) -> io::Result<UdpSocket> {
    let socket = socket_factory::udp(socket_addr)?;
    setsockopt(&socket, sockopt::Mark, &FIREZONE_MARK)?;
    Ok(socket)
}
