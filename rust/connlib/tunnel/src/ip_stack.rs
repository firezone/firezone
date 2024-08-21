use core::fmt;
use std::net::IpAddr;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum IpStack {
    None,
    V4,
    V6,
    Dual,
}

impl fmt::Display for IpStack {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            IpStack::None => write!(f, "None"),
            IpStack::V4 => write!(f, "IPv4-only"),
            IpStack::V6 => write!(f, "IPv6-only"),
            IpStack::Dual => write!(f, "Dual (IPv4 & IPv6)"),
        }
    }
}

impl IpStack {
    pub fn can_send(&self, ip: IpAddr) -> bool {
        match (self, ip) {
            (IpStack::None, _) => false,
            (IpStack::Dual, _) => true,
            (IpStack::V4, IpAddr::V4(_)) => true,
            (IpStack::V6, IpAddr::V6(_)) => true,
            (IpStack::V4, IpAddr::V6(_)) => false,
            (IpStack::V6, IpAddr::V4(_)) => false,
        }
    }
}
