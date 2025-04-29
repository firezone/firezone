#[derive(clap::ValueEnum, Clone, Copy, Debug, Default)]
pub enum DnsControlMethod {
    #[default]
    None,
}

pub use socket_factory::tcp as tcp_socket_factory;
pub use socket_factory::udp as udp_socket_factory;
