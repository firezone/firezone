use socket_factory::{SocketFactory, UdpSocket};
use std::io;
use std::net::SocketAddr;

pub use socket_factory::tcp as tcp_socket_factory;

#[derive(Default)]
pub struct UdpSocketFactory {}

impl SocketFactory<UdpSocket> for UdpSocketFactory {
    fn bind(&self, local: SocketAddr) -> io::Result<UdpSocket> {
        socket_factory::udp(local)
    }

    fn reset(&self) {}
}
