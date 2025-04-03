use core::num::NonZeroUsize;

#[derive(Debug, Clone, Copy)]
pub enum Error {
    PacketTooShort,
    NotUdp,
    NotTurn,
    NotIp,
    NoMacAddress,
    Ipv4PacketWithOptions,
    NotAChannelDataMessage,
    BadChannelDataLength,
    NoEntry(SupportedChannel),
    UnsupportedChannel(UnsupportedChannel),
    XdpLoadBytesFailed,
    XdpAdjustHeadFailed,
    XdpStoreBytesFailed,
}

#[derive(Debug, Clone, Copy)]
pub enum SupportedChannel {
    UdpToChan44,
    ChanToUdp44,
    UdpToChan66,
    ChanToUdp66,
}

#[derive(Debug, Clone, Copy)]
pub enum UnsupportedChannel {
    UdpToChan46,
    ChanToUdp46,
    UdpToChan64,
    ChanToUdp64,
}

impl aya_log_ebpf::WriteToBuf for Error {
    #[inline(always)]
    fn write(self, buf: &mut [u8]) -> Option<NonZeroUsize> {
        let msg = match self {
            Error::PacketTooShort => "Packet is too short",
            Error::NotUdp => "Not a UDP packet",
            Error::NotTurn => "Not TURN traffic",
            Error::NotIp => "Not an IP packet",
            Error::NoMacAddress => "No MAC address",
            Error::Ipv4PacketWithOptions => "IPv4 packet has options",
            Error::NotAChannelDataMessage => "Not a channel data message",
            Error::BadChannelDataLength => "Channel data length does not match packet length",
            Error::NoEntry(SupportedChannel::UdpToChan44) => {
                "No entry in UDPv4 to channel IPv4 map"
            }
            Error::NoEntry(SupportedChannel::ChanToUdp44) => {
                "No entry in channel IPv4 to UDPv4 map"
            }
            Error::NoEntry(SupportedChannel::UdpToChan66) => {
                "No entry in UDPv6 to channel IPv6 map"
            }
            Error::NoEntry(SupportedChannel::ChanToUdp66) => {
                "No entry in channel IPv6 to UDPv6 map"
            }
            Error::UnsupportedChannel(UnsupportedChannel::UdpToChan46) => {
                "Relaying UDPv4 to channel IPv6 is not supported"
            }
            Error::UnsupportedChannel(UnsupportedChannel::ChanToUdp46) => {
                "Relaying channel IPv4 to UDPv6 is not supported"
            }
            Error::UnsupportedChannel(UnsupportedChannel::UdpToChan64) => {
                "Relaying UDPv6 to channel IPv4 is not supported"
            }
            Error::UnsupportedChannel(UnsupportedChannel::ChanToUdp64) => {
                "Relaying channel IPv6 to UDPv4 is not supported"
            }
            Error::XdpLoadBytesFailed => "Failed to load bytes",
            Error::XdpAdjustHeadFailed => "Failed to adjust head",
            Error::XdpStoreBytesFailed => "Failed to store bytes",
        };

        msg.write(buf)
    }
}

impl aya_log_ebpf::macro_support::DefaultFormatter for Error {}
