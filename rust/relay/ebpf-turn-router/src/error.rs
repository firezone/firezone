use core::num::NonZeroUsize;

#[derive(Debug, Clone, Copy)]
pub enum Error {
    PacketTooShort,
    Loopback,
    NotUdp,
    NotTurn,
    NotIp,
    NoMacAddress,
    Ipv4PacketWithOptions,
    NotAChannelDataMessage,
    BadChannelDataLength,
    NoChannelBinding,
    XdpLoadBytesFailed,
    XdpAdjustHeadFailed,
    XdpStoreBytesFailed,
}

impl aya_log_ebpf::WriteToBuf for Error {
    fn write(self, buf: &mut [u8]) -> Option<NonZeroUsize> {
        let msg = match self {
            Error::PacketTooShort => "Packet is too short",
            Error::Loopback => "Loopback packet",
            Error::NotUdp => "Not a UDP packet",
            Error::NotTurn => "Not TURN traffic",
            Error::NotIp => "Not an IP packet",
            Error::NoMacAddress => "No MAC address",
            Error::Ipv4PacketWithOptions => "IPv4 packet has options",
            Error::NotAChannelDataMessage => "Not a channel data message",
            Error::BadChannelDataLength => "Channel data length does not match packet length",
            Error::NoChannelBinding => "No channel binding",
            Error::XdpLoadBytesFailed => "Failed to load bytes",
            Error::XdpAdjustHeadFailed => "Failed to adjust head",
            Error::XdpStoreBytesFailed => "Failed to store bytes",
        };

        msg.write(buf)
    }
}

impl aya_log_ebpf::macro_support::DefaultFormatter for Error {}
