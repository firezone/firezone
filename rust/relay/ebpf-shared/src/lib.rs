#![cfg_attr(not(feature = "userspace"), no_std)]

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "userspace", derive(Debug))]
pub struct SocketAddrV4 {
    pub ipv4_address: u32,
    pub port: u16,
}

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "userspace", derive(Debug))]
pub struct ChannelNumber(pub u16);

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "userspace", derive(Debug))]
pub struct ClientAndChannel(pub SocketAddrV4, pub ChannelNumber);

#[repr(C)]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "userspace", derive(Debug))]
pub struct PortAndPeer(pub u16, pub SocketAddrV4);

#[cfg(feature = "userspace")]
mod userspace {
    use super::*;

    unsafe impl aya::Pod for SocketAddrV4 {}

    impl From<std::net::SocketAddrV4> for SocketAddrV4 {
        fn from(value: std::net::SocketAddrV4) -> Self {
            SocketAddrV4 {
                ipv4_address: value.ip().to_bits(),
                port: value.port(),
            }
        }
    }

    unsafe impl aya::Pod for ChannelNumber {}

    unsafe impl aya::Pod for ClientAndChannel {}

    unsafe impl aya::Pod for PortAndPeer {}
}
