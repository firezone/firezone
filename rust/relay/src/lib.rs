mod allocation;
mod auth;
mod net_ext;
mod server;
mod sleep;
mod time_events;
mod udp_socket;

pub mod health_check;
#[cfg(feature = "proptest")]
pub mod proptest;

pub use allocation::Allocation;
pub use net_ext::{IpAddrExt, SocketAddrExt};
pub use server::{
    channel_data, Allocate, AllocationId, Attribute, Binding, ChannelBind, ClientMessage, Command,
    CreatePermission, Refresh, Server,
};
pub use sleep::Sleep;
pub use stun_codec::rfc8656::attributes::AddressFamily;
pub use udp_socket::UdpSocket;

pub(crate) use time_events::TimeEvents;

use std::net::{Ipv4Addr, Ipv6Addr};

/// Describes the IP stack of a relay server.
#[derive(Debug, Copy, Clone)]
pub enum IpStack {
    Ip4(Ipv4Addr),
    Ip6(Ipv6Addr),
    Dual { ip4: Ipv4Addr, ip6: Ipv6Addr },
}

impl IpStack {
    pub fn as_v4(&self) -> Option<&Ipv4Addr> {
        match self {
            IpStack::Ip4(ip4) => Some(ip4),
            IpStack::Ip6(_) => None,
            IpStack::Dual { ip4, .. } => Some(ip4),
        }
    }

    pub fn as_v6(&self) -> Option<&Ipv6Addr> {
        match self {
            IpStack::Ip4(_) => None,
            IpStack::Ip6(ip6) => Some(ip6),
            IpStack::Dual { ip6, .. } => Some(ip6),
        }
    }
}

impl From<Ipv4Addr> for IpStack {
    fn from(value: Ipv4Addr) -> Self {
        IpStack::Ip4(value)
    }
}

impl From<Ipv6Addr> for IpStack {
    fn from(value: Ipv6Addr) -> Self {
        IpStack::Ip6(value)
    }
}

impl From<(Ipv4Addr, Ipv6Addr)> for IpStack {
    fn from((ip4, ip6): (Ipv4Addr, Ipv6Addr)) -> Self {
        IpStack::Dual { ip4, ip6 }
    }
}
