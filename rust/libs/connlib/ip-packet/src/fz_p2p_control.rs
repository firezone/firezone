use std::net::Ipv6Addr;

use etherparse::IpNumber;

/// The src and dst of a FZ p2p control protocol packet.
///
/// No actual IP packet can be sent to the unspecified IPv6 addr.
/// This allows us to unambiguously identify our control protocol packets among the others.
pub const ADDR: Ipv6Addr = Ipv6Addr::UNSPECIFIED;

/// The IP protocol of FZ p2p control protocol packets.
///
/// `0xFF` is reserved and should thus never appear as real-world traffic.
pub const IP_NUMBER: IpNumber = IpNumber(0xFF);

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub struct EventType(u8);

impl EventType {
    pub const fn new(ty: u8) -> Self {
        Self(ty)
    }

    pub fn into_u8(self) -> u8 {
        self.0
    }
}
