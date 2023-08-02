use crate::rfc8656::AddressFamily;
use std::net::{IpAddr, SocketAddr};

pub trait IpAddrExt {
    fn family(&self) -> AddressFamily;
}

impl IpAddrExt for IpAddr {
    fn family(&self) -> AddressFamily {
        match self {
            IpAddr::V4(_) => AddressFamily::V4,
            IpAddr::V6(_) => AddressFamily::V6,
        }
    }
}

pub trait SocketAddrExt {
    fn family(&self) -> AddressFamily;
}

impl SocketAddrExt for SocketAddr {
    fn family(&self) -> AddressFamily {
        match self {
            SocketAddr::V4(_) => AddressFamily::V4,
            SocketAddr::V6(_) => AddressFamily::V6,
        }
    }
}
