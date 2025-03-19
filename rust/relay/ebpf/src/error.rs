use core::num::NonZeroUsize;

#[derive(Debug)]
pub enum Error {
    Ethernet2Header,
    Ipv4Header,
    UdpHeader,
    NotImplemented,
    PacketTooShort,
}

impl aya_log_ebpf::WriteToBuf for Error {
    fn write(self, buf: &mut [u8]) -> Option<NonZeroUsize> {
        let msg = match self {
            Error::Ethernet2Header => "Failed to parse Ethernet2 header",
            Error::Ipv4Header => "Failed to parse IPv4 header",
            Error::UdpHeader => "Failed to parse UDP header",
            Error::NotImplemented => "Not implemented",
            Error::PacketTooShort => "Packet is too short",
        };

        msg.write(buf)
    }
}

impl aya_log_ebpf::macro_support::DefaultFormatter for Error {}
