#![cfg_attr(not(feature = "userspace"), no_std)]

#[repr(C, align(32))]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "userspace", derive(Debug))]
pub struct SocketAddrV4 {
    pub ipv4_address: u32,
    pub port: u16,
}

#[repr(C, align(32))]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "userspace", derive(Debug))]
pub struct ChannelNumber(pub u16);

#[repr(C, align(32))]
#[derive(Clone, Copy)]
#[cfg_attr(feature = "userspace", derive(Debug))]
pub struct ClientAndChannel(pub SocketAddrV4, pub ChannelNumber);

#[repr(C, align(32))]
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

#[cfg(all(test, feature = "userspace"))]
mod tests {
    use super::*;
    use std::mem::{align_of, size_of};

    #[test]
    fn check_alignments() {
        println!(
            "SocketAddrV4: size = {}, align = {}",
            size_of::<SocketAddrV4>(),
            align_of::<SocketAddrV4>()
        );
        println!(
            "ChannelNumber: size = {}, align = {}",
            size_of::<ChannelNumber>(),
            align_of::<ChannelNumber>()
        );
        println!(
            "ClientAndChannel: size = {}, align = {}",
            size_of::<ClientAndChannel>(),
            align_of::<ClientAndChannel>()
        );
        println!(
            "PortAndPeer: size = {}, align = {}",
            size_of::<PortAndPeer>(),
            align_of::<PortAndPeer>()
        );
    }
}
