//! Shared data structures between the kernel and userspace.
//!
//! To learn more about the layout requirements of these structs, read <https://github.com/foniod/redbpf/issues/150#issuecomment-964017857>.
//! In order to make sure endianness is correct, we store everything in byte-arrays in _big-endian_ order.
//! This makes it easier to directly take the values from the network buffer and use them in these structs (and vice-versa).

#![cfg_attr(not(feature = "std"), no_std)]

use core::net::{Ipv4Addr, Ipv6Addr};

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "std", derive(Debug))]
pub struct ClientAndChannelV4 {
    ipv4_address: [u8; 4],
    _padding_ipv4_address: [u8; 4],

    port: [u8; 2],
    _padding_port: [u8; 6],

    channel: [u8; 2],
    _padding_channel: [u8; 6],

    _padding_struct: [u8; 40],
}

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "std", derive(Debug))]
pub struct ClientAndChannelV6 {
    ipv6_address: [u8; 16],

    port: [u8; 2],
    _padding_port: [u8; 6],

    channel: [u8; 2],
    _padding_channel: [u8; 6],

    _padding_struct: [u8; 32],
}

impl ClientAndChannelV4 {
    pub fn new(ipv4_address: Ipv4Addr, port: u16, channel: u16) -> Self {
        Self {
            ipv4_address: ipv4_address.octets(),
            _padding_ipv4_address: [0u8; 4],

            port: port.to_be_bytes(),
            _padding_port: [0u8; 6],

            channel: channel.to_be_bytes(),
            _padding_channel: [0u8; 6],

            _padding_struct: [0u8; 40],
        }
    }

    pub fn from_socket(src: core::net::SocketAddrV4, channel: u16) -> Self {
        Self::new(*src.ip(), src.port(), channel)
    }

    pub fn client_ip(&self) -> Ipv4Addr {
        self.ipv4_address.into()
    }

    pub fn client_port(&self) -> u16 {
        u16::from_be_bytes(self.port)
    }

    pub fn channel(&self) -> u16 {
        u16::from_be_bytes(self.channel)
    }
}

impl ClientAndChannelV6 {
    pub fn new(ipv6_address: Ipv6Addr, port: u16, channel: u16) -> Self {
        Self {
            ipv6_address: ipv6_address.octets(),

            port: port.to_be_bytes(),
            _padding_port: [0u8; 6],

            channel: channel.to_be_bytes(),
            _padding_channel: [0u8; 6],

            _padding_struct: [0u8; 32],
        }
    }

    pub fn from_socket(src: core::net::SocketAddrV6, channel: u16) -> Self {
        Self::new(*src.ip(), src.port(), channel)
    }

    pub fn client_ip(&self) -> Ipv6Addr {
        self.ipv6_address.into()
    }

    pub fn client_port(&self) -> u16 {
        u16::from_be_bytes(self.port)
    }

    pub fn channel(&self) -> u16 {
        u16::from_be_bytes(self.channel)
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "std", derive(Debug))]
pub struct PortAndPeerV4 {
    ipv4_address: [u8; 4],
    _padding_ipv4_address: [u8; 4],

    allocation_port: [u8; 2],
    _padding_allocation_port: [u8; 6],

    peer_port: [u8; 2],
    _padding_dest_port: [u8; 6],

    _padding_struct: [u8; 40],
}

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "std", derive(Debug))]
pub struct PortAndPeerV6 {
    ipv6_address: [u8; 16],

    allocation_port: [u8; 2],
    _padding_allocation_port: [u8; 6],

    peer_port: [u8; 2],
    _padding_dest_port: [u8; 6],

    _padding_struct: [u8; 32],
}

impl PortAndPeerV4 {
    pub fn new(ipv4_address: Ipv4Addr, allocation_port: u16, peer_port: u16) -> Self {
        Self {
            ipv4_address: ipv4_address.octets(),
            _padding_ipv4_address: [0u8; 4],

            allocation_port: allocation_port.to_be_bytes(),
            _padding_allocation_port: [0u8; 6],

            peer_port: peer_port.to_be_bytes(),
            _padding_dest_port: [0u8; 6],

            _padding_struct: [0u8; 40],
        }
    }

    pub fn from_socket(dst: core::net::SocketAddrV4, allocation_port: u16) -> Self {
        Self::new(*dst.ip(), allocation_port, dst.port())
    }

    pub fn peer_ip(&self) -> Ipv4Addr {
        self.ipv4_address.into()
    }

    pub fn allocation_port(&self) -> u16 {
        u16::from_be_bytes(self.allocation_port)
    }

    pub fn peer_port(&self) -> u16 {
        u16::from_be_bytes(self.peer_port)
    }
}

impl PortAndPeerV6 {
    pub fn new(ipv6_address: Ipv6Addr, allocation_port: u16, peer_port: u16) -> Self {
        Self {
            ipv6_address: ipv6_address.octets(),

            allocation_port: allocation_port.to_be_bytes(),
            _padding_allocation_port: [0u8; 6],

            peer_port: peer_port.to_be_bytes(),
            _padding_dest_port: [0u8; 6],

            _padding_struct: [0u8; 32],
        }
    }

    pub fn from_socket(dst: core::net::SocketAddrV6, allocation_port: u16) -> Self {
        Self::new(*dst.ip(), allocation_port, dst.port())
    }

    pub fn peer_ip(&self) -> Ipv6Addr {
        self.ipv6_address.into()
    }

    pub fn allocation_port(&self) -> u16 {
        u16::from_be_bytes(self.allocation_port)
    }

    pub fn peer_port(&self) -> u16 {
        u16::from_be_bytes(self.peer_port)
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "std", derive(Debug))]
pub struct Config {
    pub udp_checksum_enabled: bool,
    pub lowest_allocation_port: u16,
    pub highest_allocation_port: u16,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            udp_checksum_enabled: true,
            lowest_allocation_port: 49152,
            highest_allocation_port: 65535,
        }
    }
}

#[cfg(all(feature = "std", target_os = "linux"))]
mod userspace {
    use super::*;

    unsafe impl aya::Pod for ClientAndChannelV4 {}

    unsafe impl aya::Pod for PortAndPeerV4 {}

    unsafe impl aya::Pod for ClientAndChannelV6 {}

    unsafe impl aya::Pod for PortAndPeerV6 {}

    unsafe impl aya::Pod for Config {}
}

#[cfg(all(test, feature = "std"))]
mod tests {
    use super::*;

    #[test]
    fn client_and_channel_v4_has_size_64() {
        assert_eq!(std::mem::size_of::<ClientAndChannelV4>(), 64)
    }

    #[test]
    fn port_and_peer_v4_has_size_64() {
        assert_eq!(std::mem::size_of::<PortAndPeerV4>(), 64)
    }

    #[test]
    fn client_and_channel_v6_has_size_64() {
        assert_eq!(std::mem::size_of::<ClientAndChannelV6>(), 64)
    }

    #[test]
    fn port_and_peer_v6_has_size_64() {
        assert_eq!(std::mem::size_of::<PortAndPeerV6>(), 64)
    }
}
