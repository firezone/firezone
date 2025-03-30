//! Shared data structures between the kernel and userspace.
//!
//! To learn more about the layout requirements of these structs, read <https://github.com/foniod/redbpf/issues/150#issuecomment-964017857>.

#![cfg_attr(not(feature = "std"), no_std)]

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "std", derive(Debug))]
pub struct ClientAndChannelV4 {
    ipv4_address: [u8; 4],
    _padding_ipv4_address: [u8; 4],

    port: u16,
    _padding_port: [u8; 6],

    channel: u16,
    _padding_channel: [u8; 6],

    _padding_struct: [u8; 40],
}

impl ClientAndChannelV4 {
    pub fn new(ipv4_address: [u8; 4], port: u16, channel: u16) -> Self {
        Self {
            ipv4_address,
            _padding_ipv4_address: [0u8; 4],

            port: port.to_be(),
            _padding_port: [0u8; 6],

            channel: channel.to_be(),
            _padding_channel: [0u8; 6],

            _padding_struct: [0u8; 40],
        }
    }

    pub fn from_socket(src: core::net::SocketAddrV4, channel: u16) -> Self {
        Self::new(src.ip().octets(), src.port(), channel)
    }

    pub fn client_ip(&self) -> [u8; 4] {
        self.ipv4_address
    }

    pub fn client_port(&self) -> u16 {
        self.port
    }

    pub fn channel(&self) -> u16 {
        self.channel
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "std", derive(Debug))]
pub struct PortAndPeerV4 {
    ipv4_address: [u8; 4],
    _padding_ipv4_address: [u8; 4],

    allocation_port: u16,
    _padding_allocation_port: [u8; 6],

    peer_port: u16,
    _padding_dest_port: [u8; 6],

    _padding_struct: [u8; 40],
}

impl PortAndPeerV4 {
    pub fn new(ipv4_address: [u8; 4], allocation_port: u16, peer_port: u16) -> Self {
        Self {
            ipv4_address,
            _padding_ipv4_address: [0u8; 4],

            allocation_port,
            _padding_allocation_port: [0u8; 6],

            peer_port,
            _padding_dest_port: [0u8; 6],

            _padding_struct: [0u8; 40],
        }
    }

    pub fn from_socket(dst: core::net::SocketAddrV4, allocation_port: u16) -> Self {
        Self::new(dst.ip().octets(), allocation_port, dst.port())
    }

    pub fn peer_ip(&self) -> [u8; 4] {
        self.ipv4_address
    }

    pub fn allocation_port(&self) -> u16 {
        self.allocation_port
    }

    pub fn peer_port(&self) -> u16 {
        self.peer_port
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

    unsafe impl aya::Pod for Config {}
}

#[cfg(all(test, feature = "std"))]
mod tests {
    use super::*;

    #[test]
    fn client_and_channel_has_size_64() {
        assert_eq!(std::mem::size_of::<ClientAndChannelV4>(), 64)
    }

    #[test]
    fn port_and_peer_has_size_64() {
        assert_eq!(std::mem::size_of::<PortAndPeerV4>(), 64)
    }
}
