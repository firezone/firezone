use core::num::NonZeroUsize;

use aya_ebpf::bindings::xdp_action;

#[derive(Debug, Clone, Copy)]
pub enum Error {
    PacketTooShort,
    Ipv4PacketWithOptions,
    NotAChannelDataMessage,
    BadChannelDataLength,
    NoChannelBinding,
}

impl Error {
    pub fn xdp_action(&self) -> xdp_action::Type {
        match self {
            Error::PacketTooShort => xdp_action::XDP_PASS,
            Error::Ipv4PacketWithOptions => xdp_action::XDP_PASS,
            Error::BadChannelDataLength => xdp_action::XDP_DROP,
            Error::NotAChannelDataMessage => xdp_action::XDP_PASS,
            Error::NoChannelBinding => xdp_action::XDP_PASS,
        }
    }
}

impl aya_log_ebpf::WriteToBuf for Error {
    fn write(self, buf: &mut [u8]) -> Option<NonZeroUsize> {
        let msg = match self {
            Error::PacketTooShort => "Packet is too short",
            Error::Ipv4PacketWithOptions => "IPv4 packet has options",
            Error::NotAChannelDataMessage => "Not a channel data message",
            Error::BadChannelDataLength => "Channel data length does not match packet length",
            Error::NoChannelBinding => "No channel binding",
        };

        msg.write(buf)
    }
}

impl aya_log_ebpf::macro_support::DefaultFormatter for Error {}
