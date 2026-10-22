use std::net::IpAddr;
use stun_codec::rfc8656::attributes::AddressFamily;

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
