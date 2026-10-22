use std::{io, net::SocketAddr};

use crate::FIREZONE_MARK;
use nix::sys::socket::{setsockopt, sockopt};
use socket_factory::{RoutingLoopPreventionFailed, SocketFactory, TcpSocket, UdpSocket};

pub fn tcp_socket_factory(socket_addr: SocketAddr) -> io::Result<TcpSocket> {
    let socket = socket_factory::tcp(socket_addr)?;
    setsockopt(&socket, sockopt::Mark, &FIREZONE_MARK).map_err(RoutingLoopPreventionFailed::new)?;
    Ok(socket)
}

#[derive(Default)]
pub struct UdpSocketFactory {}

impl SocketFactory<UdpSocket> for UdpSocketFactory {
    fn bind(&self, local: SocketAddr) -> io::Result<UdpSocket> {
        let socket = socket_factory::udp(local)?;
        setsockopt(&socket, sockopt::Mark, &FIREZONE_MARK)
            .map_err(RoutingLoopPreventionFailed::new)?;
        Ok(socket)
    }

    fn reset(&self) {}
}
