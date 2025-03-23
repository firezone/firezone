#![cfg_attr(test, allow(clippy::unwrap_used))]

mod net_ext;
mod server;
mod sleep;

pub mod auth;
pub mod ebpf;
#[cfg(feature = "proptest")]
#[allow(clippy::unwrap_used)]
pub mod proptest;
pub mod sockets;

pub use net_ext::IpAddrExt;
pub use server::{
    Allocate, AllocationPort, Attribute, Binding, ChannelBind, ChannelData, ClientMessage, Command,
    CreatePermission, Refresh, Server,
};
pub use sleep::Sleep;
use stun_codec::rfc5389::attributes::Software;
pub use stun_codec::rfc8656::attributes::AddressFamily;

use std::{
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::LazyLock,
};

pub const VERSION: Option<&str> = option_env!("GITHUB_SHA");
pub static SOFTWARE: LazyLock<Software> = LazyLock::new(|| {
    Software::new(format!(
        "firezone-relay; rev={}",
        VERSION.map(|rev| &rev[..8]).unwrap_or("xxxx")
    ))
    .expect("less than 128 chars")
});

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

impl From<IpAddr> for IpStack {
    fn from(value: IpAddr) -> Self {
        match value {
            IpAddr::V4(inner) => IpStack::Ip4(inner),
            IpAddr::V6(inner) => IpStack::Ip6(inner),
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

impl From<(Option<Ipv4Addr>, Option<Ipv6Addr>)> for IpStack {
    fn from((ip4, ip6): (Option<Ipv4Addr>, Option<Ipv6Addr>)) -> Self {
        match (ip4, ip6) {
            (None, None) => panic!("must have at least one IP"),
            (None, Some(ip6)) => IpStack::from(ip6),
            (Some(ip4), None) => IpStack::from(ip4),
            (Some(ip4), Some(ip6)) => IpStack::from((ip4, ip6)),
        }
    }
}

/// New-type for a client's socket.
///
/// From the [spec](https://www.rfc-editor.org/rfc/rfc8656#section-2-4.4):
///
/// > A STUN client that implements this specification.
#[derive(Debug, PartialEq, Eq, Hash, Clone, Copy, PartialOrd, Ord)]
pub struct ClientSocket(SocketAddr);

impl ClientSocket {
    pub fn new(addr: SocketAddr) -> Self {
        Self(addr)
    }

    pub fn into_socket(self) -> SocketAddr {
        self.0
    }

    pub fn family(&self) -> AddressFamily {
        match self.0 {
            SocketAddr::V4(_) => AddressFamily::V4,
            SocketAddr::V6(_) => AddressFamily::V6,
        }
    }
}

impl fmt::Display for ClientSocket {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

/// New-type for a peer's socket.
///
/// From the [spec](https://www.rfc-editor.org/rfc/rfc8656#section-2-4.8):
///
/// > A host with which the TURN client wishes to communicate. The TURN server relays traffic between the TURN client and its peer(s). The peer does not interact with the TURN server using the protocol defined in this document; rather, the peer receives data sent by the TURN server, and the peer sends data towards the TURN server.
#[derive(Debug, PartialEq, Eq, Hash, Clone, Copy)]
pub struct PeerSocket(SocketAddr);

impl PeerSocket {
    pub fn new(addr: SocketAddr) -> Self {
        Self(addr)
    }

    pub fn family(&self) -> AddressFamily {
        match self.0 {
            SocketAddr::V4(_) => AddressFamily::V4,
            SocketAddr::V6(_) => AddressFamily::V6,
        }
    }

    pub fn into_socket(self) -> SocketAddr {
        self.0
    }
}

impl fmt::Display for PeerSocket {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}
