#[derive(Debug, Clone, Copy)]
pub enum Error {
    ArrayIndexOutOfBounds,
    IpAddrUnset,
    UdpChecksumMissing,
    PacketTooShort,
    NotUdp,
    DnsPacket,
    NotTurn,
    NotIp,
    Ipv4PacketWithOptions,
    NotAChannelDataMessage,
    BadChannelDataLength,
    NoEntry(SupportedChannel),
    XdpAdjustHeadFailed,
}

#[derive(Debug, Clone, Copy)]
pub enum SupportedChannel {
    Udp4ToChan,
    Chan4ToUdp,
    Udp6ToChan,
    Chan6ToUdp,
}

impl Error {
    #[inline(always)]
    pub fn as_str(&self) -> &'static str {
        match self {
            Error::ArrayIndexOutOfBounds => "Array index is out of bounds",
            Error::IpAddrUnset => "IP address has not been configured",
            Error::UdpChecksumMissing => "UDP checksum is missing",
            Error::PacketTooShort => "Packet is too short",
            Error::NotUdp => "Not a UDP packet",
            Error::DnsPacket => "DNS packet",
            Error::NotTurn => "Not TURN traffic",
            Error::NotIp => "Not an IP packet",
            Error::Ipv4PacketWithOptions => "IPv4 packet has options",
            Error::NotAChannelDataMessage => "Not a channel data message",
            Error::BadChannelDataLength => "Channel data length does not match packet length",
            Error::NoEntry(ch) => match ch {
                SupportedChannel::Udp4ToChan => "No entry in UDPv4 to channel IPv4 or IPv6 map",
                SupportedChannel::Chan4ToUdp => "No entry in channel IPv4 to UDPv4 or UDPv6 map",
                SupportedChannel::Udp6ToChan => "No entry in UDPv6 to channel IPv4 or IPv6 map",
                SupportedChannel::Chan6ToUdp => "No entry in channel IPv6 to UDPv4 or UDPv6 map",
            },
            Error::XdpAdjustHeadFailed => "Failed to adjust tail",
        }
    }
}

impl aya_log_ebpf::macro_support::DefaultFormatter for Error {}
