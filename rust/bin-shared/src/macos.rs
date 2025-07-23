pub use socket_factory::tcp as tcp_socket_factory;

pub struct UdpSocketFactory;

impl SocketFactory<UdpSocket> for UdpSocketFactory {
    fn bind(&self, local: SocketAddr) -> io::Result<UdpSocket> {
        socket_factory::udp(socket_addr)
    }

    fn reset(&self) {}
}

impl Default for UdpSocketFactory {
    fn default() -> Self {
        Self
    }
}
