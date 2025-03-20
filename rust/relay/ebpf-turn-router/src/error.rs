use core::num::NonZeroUsize;

use aya_ebpf::bindings::xdp_action;

#[derive(Debug)]
pub enum Error {
    Ethernet2Header,
    Ipv4Header,
    UdpHeader,
    NotImplemented,
    PacketTooShort,
    Ipv4PacketWithOptions,
    NotUdp,
}

impl Error {
    pub fn xdp_action(&self) -> xdp_action::Type {
        match self {
            Error::Ethernet2Header => xdp_action::XDP_PASS,
            Error::Ipv4Header => xdp_action::XDP_PASS,
            Error::UdpHeader => xdp_action::XDP_PASS,
            Error::NotImplemented => xdp_action::XDP_PASS,
            Error::PacketTooShort => xdp_action::XDP_PASS,
            Error::Ipv4PacketWithOptions => xdp_action::XDP_PASS,
            Error::NotUdp => xdp_action::XDP_PASS,
        }
    }
}

impl aya_log_ebpf::WriteToBuf for Error {
    fn write(self, buf: &mut [u8]) -> Option<NonZeroUsize> {
        let msg = match self {
            Error::Ethernet2Header => "Failed to parse Ethernet2 header",
            Error::Ipv4Header => "Failed to parse IPv4 header",
            Error::UdpHeader => "Failed to parse UDP header",
            Error::NotImplemented => "Not implemented",
            Error::PacketTooShort => "Packet is too short",
            Error::Ipv4PacketWithOptions => "IPv4 packet has optiosn",
            Error::NotUdp => "Not a UDP packet",
        };

        msg.write(buf)
    }
}

impl aya_log_ebpf::macro_support::DefaultFormatter for Error {}
