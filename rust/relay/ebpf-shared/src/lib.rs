#![cfg_attr(not(feature = "userspace"), no_std)]

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "userspace", derive(Debug))]
pub struct ClientAndChannel {
    ipv4_address: u32,
    _padding_ipv4_address: [u8; 4],

    port: u16,
    _padding_port: [u8; 6],

    channel: u16,
    _padding_channel: [u8; 6],

    _padding_struct: [u8; 40],
}

impl ClientAndChannel {
    pub fn new(ipv4_address: u32, port: u16, channel: u16) -> Self {
        Self {
            ipv4_address: ipv4_address.to_be(),
            _padding_ipv4_address: [0u8; 4],

            port: port.to_be(),
            _padding_port: [0u8; 6],

            channel: channel.to_be(),
            _padding_channel: [0u8; 6],

            _padding_struct: [0u8; 40],
        }
    }

    pub fn from_socket(src: core::net::SocketAddrV4, channel: u16) -> Self {
        Self::new(src.ip().to_bits(), src.port(), channel)
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "userspace", derive(Debug))]
pub struct PortAndPeer {
    ipv4_address: u32,
    _padding_ipv4_address: [u8; 4],

    allocation_port: u16,
    _padding_allocation_port: [u8; 6],

    dest_port: u16,
    _padding_dest_port: [u8; 6],
}

impl PortAndPeer {
    pub fn from_socket(dst: core::net::SocketAddrV4, allocation_port: u16) -> Self {
        Self {
            ipv4_address: dst.ip().to_bits(),
            _padding_ipv4_address: [0u8; 4],
            allocation_port,
            _padding_allocation_port: [0u8; 6],
            dest_port: dst.port(),
            _padding_dest_port: [0u8; 6],
        }
    }

    pub fn dest_ip(&self) -> u32 {
        self.ipv4_address
    }

    pub fn allocation_port(&self) -> u16 {
        self.allocation_port
    }

    pub fn dest_port(&self) -> u16 {
        self.dest_port
    }
}

#[cfg(feature = "userspace")]
mod userspace {
    use super::*;

    unsafe impl aya::Pod for ClientAndChannel {}

    unsafe impl aya::Pod for PortAndPeer {}
}

#[cfg(all(test, feature = "userspace"))]
mod tests {
    use super::*;

    #[test]
    fn client_and_channel_as_size_64() {
        assert_eq!(std::mem::size_of::<ClientAndChannel>(), 64)
    }
}
