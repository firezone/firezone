mod auth;
mod rfc8656;
mod server;
mod sleep;
mod stun_codec_ext;
mod time_events;
mod udp_socket;

#[cfg(feature = "proptest")]
pub mod proptest;

pub use server::{
    Allocate, AllocationId, Attribute, Binding, ChannelBind, ChannelData, ClientMessage, Command,
    CreatePermission, Refresh, Server,
};
pub use sleep::Sleep;
use std::net::{Ipv4Addr, Ipv6Addr};
pub use udp_socket::UdpSocket;

pub(crate) use time_events::TimeEvents;

/// Enumerates all possible IP address types, including dual-stack operation of IPv4 and IPv6.
#[derive(Debug, Copy, Clone)]
pub enum IpAddr {
    Ip4Only(Ipv4Addr),
    Ip6Only(Ipv6Addr),
    DualStack { ip4: Ipv4Addr, ip6: Ipv6Addr },
}

impl From<Ipv4Addr> for IpAddr {
    fn from(value: Ipv4Addr) -> Self {
        IpAddr::Ip4Only(value)
    }
}

impl From<Ipv6Addr> for IpAddr {
    fn from(value: Ipv6Addr) -> Self {
        IpAddr::Ip6Only(value)
    }
}

impl From<(Ipv4Addr, Ipv6Addr)> for IpAddr {
    fn from((ip4, ip6): (Ipv4Addr, Ipv6Addr)) -> Self {
        IpAddr::DualStack { ip4, ip6 }
    }
}
