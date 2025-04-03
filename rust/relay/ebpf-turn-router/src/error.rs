use core::{net::IpAddr, num::NonZeroUsize};

#[derive(Debug, Clone, Copy)]
pub enum Error {
    PacketTooShort,
    NotUdp,
    NotTurn,
    NotIp,
    NoMacAddress(IpAddr),
    Ipv4PacketWithOptions,
    NotAChannelDataMessage,
    BadChannelDataLength,
    NoEntry(SupportedChannel),
    UnsupportedChannel(UnsupportedChannel),
    XdpLoadBytesFailed(i64),
    XdpAdjustHeadFailed(i64),
    XdpStoreBytesFailed(i64),
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
        match self {
            Error::PacketTooShort => "Packet is too short".write(buf),
            Error::NotUdp => "Not a UDP packet".write(buf),
            Error::NotTurn => "Not TURN traffic".write(buf),
            Error::NotIp => "Not an IP packet".write(buf),
            Error::NoMacAddress(ip) => {
                let mut written = 0;

                written += "No MAC address for IP ".write(buf)?.get();
                written += ip.write(buf)?.get();

                NonZeroUsize::new(written)
            }
            Error::Ipv4PacketWithOptions => "IPv4 packet has options".write(buf),
            Error::NotAChannelDataMessage => "Not a channel data message".write(buf),
            Error::BadChannelDataLength => {
                "Channel data length does not match packet length".write(buf)
            }
            Error::NoEntry(SupportedChannel::UdpToChan44) => {
                "No entry in UDPv4 to channel IPv4 map.write(buf)".write(buf)
            }
            Error::NoEntry(SupportedChannel::ChanToUdp44) => {
                "No entry in channel IPv4 to UDPv4 map.write(buf)".write(buf)
            }
            Error::NoEntry(SupportedChannel::UdpToChan66) => {
                "No entry in UDPv6 to channel IPv6 map.write(buf)".write(buf)
            }
            Error::NoEntry(SupportedChannel::ChanToUdp66) => {
                "No entry in channel IPv6 to UDPv6 map.write(buf)".write(buf)
            }
            Error::UnsupportedChannel(UnsupportedChannel::UdpToChan46) => {
                "Relaying UDPv4 to channel IPv6 is not supported.write(buf)".write(buf)
            }
            Error::UnsupportedChannel(UnsupportedChannel::ChanToUdp46) => {
                "Relaying channel IPv4 to UDPv6 is not supported.write(buf)".write(buf)
            }
            Error::UnsupportedChannel(UnsupportedChannel::UdpToChan64) => {
                "Relaying UDPv6 to channel IPv4 is not supported.write(buf)".write(buf)
            }
            Error::UnsupportedChannel(UnsupportedChannel::ChanToUdp64) => {
                "Relaying channel IPv6 to UDPv4 is not supported.write(buf)".write(buf)
            }
            Error::XdpLoadBytesFailed(ret) => {
                let mut written = 0;

                written += "Failed to load bytes: ".write(buf)?.get();
                written += ret.write(buf)?.get();

                NonZeroUsize::new(written)
            }
            Error::XdpAdjustHeadFailed(ret) => {
                let mut written = 0;

                written += "Failed to adjust head: ".write(buf)?.get();
                written += ret.write(buf)?.get();

                NonZeroUsize::new(written)
            }
            Error::XdpStoreBytesFailed(ret) => {
                let mut written = 0;

                written += "Failed to store bytes: ".write(buf)?.get();
                written += ret.write(buf)?.get();

                NonZeroUsize::new(written)
            }
        }
    }
}

impl aya_log_ebpf::macro_support::DefaultFormatter for Error {}
