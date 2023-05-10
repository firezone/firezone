use std::net::{SocketAddr, SocketAddrV4, SocketAddrV6};

pub trait SocketAddrExt {
    fn try_into_v4_socket(self) -> Option<SocketAddrV4>;
    fn try_into_v6_socket(self) -> Option<SocketAddrV6>;
}

impl SocketAddrExt for SocketAddr {
    fn try_into_v4_socket(self) -> Option<SocketAddrV4> {
        match self {
            SocketAddr::V4(addr) => Some(addr),
            SocketAddr::V6(_) => None,
        }
    }

    fn try_into_v6_socket(self) -> Option<SocketAddrV6> {
        match self {
            SocketAddr::V4(_) => None,
            SocketAddr::V6(addr) => Some(addr),
        }
    }
}
