use core::num::NonZeroUsize;

use aya_ebpf::bindings::xdp_action;

#[derive(Debug, Clone, Copy)]
pub enum Error {
    ParseEthernet2Header,
    ParseIpv4Header,
    ParseUdpHeader,
    PacketTooShort,
    Ipv4PacketWithOptions,
    NotAChannelDataMessage,
    BadChannelDataLength,
}

impl Error {
    pub fn xdp_action(&self) -> xdp_action::Type {
        match self {
            Error::ParseEthernet2Header => xdp_action::XDP_PASS,
            Error::ParseIpv4Header => xdp_action::XDP_PASS,
            Error::ParseUdpHeader => xdp_action::XDP_PASS,
            Error::PacketTooShort => xdp_action::XDP_PASS,
            Error::Ipv4PacketWithOptions => xdp_action::XDP_PASS,
            Error::BadChannelDataLength => xdp_action::XDP_DROP,
            Error::NotAChannelDataMessage => xdp_action::XDP_PASS,
        }
    }
}

impl aya_log_ebpf::WriteToBuf for Error {
    fn write(self, buf: &mut [u8]) -> Option<NonZeroUsize> {
        let msg = match self {
            Error::ParseEthernet2Header => "Failed to parse Ethernet2 header",
            Error::ParseIpv4Header => "Failed to parse IPv4 header",
            Error::ParseUdpHeader => "Failed to parse UDP header",
            Error::PacketTooShort => "Packet is too short",
            Error::Ipv4PacketWithOptions => "IPv4 packet has optiosn",
            Error::NotAChannelDataMessage => "Not a channel data message",
            Error::BadChannelDataLength => "Channel data length does not match packet length",
        };

        msg.write(buf)
    }
}

impl aya_log_ebpf::macro_support::DefaultFormatter for Error {}
