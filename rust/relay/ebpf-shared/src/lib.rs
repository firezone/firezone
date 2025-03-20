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
}

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "std", derive(Debug))]
pub struct PortAndPeerV4 {
    ipv4_address: [u8; 4],
    _padding_ipv4_address: [u8; 4],

    allocation_port: u16,
    _padding_allocation_port: [u8; 6],

    dest_port: u16,
    _padding_dest_port: [u8; 6],
}

impl PortAndPeerV4 {
    pub fn from_socket(dst: core::net::SocketAddrV4, allocation_port: u16) -> Self {
        Self {
            ipv4_address: dst.ip().octets(),
            _padding_ipv4_address: [0u8; 4],
            allocation_port,
            _padding_allocation_port: [0u8; 6],
            dest_port: dst.port(),
            _padding_dest_port: [0u8; 6],
        }
    }

    pub fn dest_ip(&self) -> [u8; 4] {
        self.ipv4_address
    }

    pub fn allocation_port(&self) -> u16 {
        self.allocation_port
    }

    pub fn dest_port(&self) -> u16 {
        self.dest_port
    }
}

#[cfg(feature = "std")]
mod userspace {
    use super::*;

    unsafe impl aya::Pod for ClientAndChannelV4 {}

    unsafe impl aya::Pod for PortAndPeerV4 {}
}

#[cfg(all(test, feature = "std"))]
mod tests {
    use super::*;

    #[test]
    fn client_and_channel_has_size_64() {
        assert_eq!(std::mem::size_of::<ClientAndChannelV4>(), 64)
    }
}
