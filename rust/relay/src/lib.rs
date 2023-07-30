mod allocation;
mod auth;
mod net_ext;
mod rfc8656;
mod server;
mod sleep;
mod stun_codec_ext;
mod time_events;
mod udp_socket;

#[cfg(feature = "proptest")]
pub mod proptest;

pub use allocation::Allocation;
pub use net_ext::{IpAddrExt, SocketAddrExt};
pub use rfc8656::AddressFamily;
pub use server::{
    Allocate, AllocationId, Attribute, Binding, ChannelBind, ChannelData, ClientMessage, Command,
    CreatePermission, Refresh, Server,
};
pub use sleep::Sleep;
pub use udp_socket::UdpSocket;

pub(crate) use time_events::TimeEvents;

use std::net::{Ipv4Addr, Ipv6Addr};

/// Describes the IP stack of a relay server.
///
/// This type is generic over the particular type that is associated with each IP version which allows it to be used for addresses, sockets and other data structures.
#[derive(Debug, Copy, Clone)]
pub enum IpStack<T4, T6> {
    Ip4(T4),
    Ip6(T6),
    Dual { ip4: T4, ip6: T6 },
}

impl From<Ipv4Addr> for IpStack<Ipv4Addr, Ipv6Addr> {
    fn from(value: Ipv4Addr) -> Self {
        IpStack::Ip4(value)
    }
}

impl From<Ipv6Addr> for IpStack<Ipv4Addr, Ipv6Addr> {
    fn from(value: Ipv6Addr) -> Self {
        IpStack::Ip6(value)
    }
}

impl From<(Ipv4Addr, Ipv6Addr)> for IpStack<Ipv4Addr, Ipv6Addr> {
    fn from((ip4, ip6): (Ipv4Addr, Ipv6Addr)) -> Self {
        IpStack::Dual { ip4, ip6 }
    }
}
