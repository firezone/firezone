#[derive(Clone, Copy, Debug)]
pub enum DnsControlMethod {
    None,
}

impl Default for DnsControlMethod {
    fn default() -> Self {
        DnsControlMethod::None
    }
}

pub use socket_factory::tcp as tcp_socket_factory;
pub use socket_factory::udp as udp_socket_factory;
