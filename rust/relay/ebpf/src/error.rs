use core::num::NonZeroUsize;

#[derive(Debug)]
pub enum Error {
    Ethernet2Header,
    Ipv4Header,
    UdpHeader,
    UdpChecksum,
    NotImplemented,
    PacketTooShort,
}

impl aya_log_ebpf::WriteToBuf for Error {
    fn write(self, buf: &mut [u8]) -> Option<NonZeroUsize> {
        let msg = match self {
            Error::Ethernet2Header => "Failed to parse Ethernet2 header",
            Error::Ipv4Header => "Failed to parse IPv4 header",
            Error::UdpHeader => "Failed to parse UDP header",
            Error::UdpChecksum => "Failed to calculate UDP checksum",
            Error::NotImplemented => "Not implemented",
            Error::PacketTooShort => "Packet is too short",
        }
        .as_bytes();

        if buf.len() < msg.len() {
            return None;
        }

        // SAFETY:
        // - We checked that `buf` is long enough.
        // - We pass the length of the string.
        unsafe { aya_ebpf::memcpy(buf.as_mut_ptr(), msg.as_ptr() as *mut u8, msg.len()) };

        // SAFETY: All strings are non-zero in length.
        Some(unsafe { NonZeroUsize::new_unchecked(msg.len()) })
    }
}

impl aya_log_ebpf::macro_support::DefaultFormatter for Error {}
