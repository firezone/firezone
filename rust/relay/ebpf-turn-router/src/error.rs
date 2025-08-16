use core::num::NonZeroUsize;

#[derive(Debug, Clone, Copy)]
pub enum Error {
    PacketTooShort,
    NotUdp,
    NotTurn,
    NotIp,
    Ipv4PacketWithOptions,
    NotAChannelDataMessage,
    BadChannelDataLength,
    NoEntry(SupportedChannel),
    UnsupportedChannel(UnsupportedChannel),
    XdpAdjustTailFailed(i64),
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
        // Use a simpler match structure to help the verifier
        let msg = match self {
            Error::PacketTooShort => "Packet is too short",
            Error::NotUdp => "Not a UDP packet",
            Error::NotTurn => "Not TURN traffic",
            Error::NotIp => "Not an IP packet",
            Error::Ipv4PacketWithOptions => "IPv4 packet has options",
            Error::NotAChannelDataMessage => "Not a channel data message",
            Error::BadChannelDataLength => "Channel data length does not match packet length",
            Error::NoEntry(ch) => match ch {
                SupportedChannel::UdpToChan44 => "No entry in UDPv4 to channel IPv4 map",
                SupportedChannel::ChanToUdp44 => "No entry in channel IPv4 to UDPv4 map",
                SupportedChannel::UdpToChan66 => "No entry in UDPv6 to channel IPv6 map",
                SupportedChannel::ChanToUdp66 => "No entry in channel IPv6 to UDPv6 map",
            },
            Error::UnsupportedChannel(ch) => match ch {
                UnsupportedChannel::UdpToChan46 => {
                    "Relaying UDPv4 to channel IPv6 is not supported"
                }
                UnsupportedChannel::ChanToUdp46 => {
                    "Relaying channel IPv4 to UDPv6 is not supported"
                }
                UnsupportedChannel::UdpToChan64 => {
                    "Relaying UDPv6 to channel IPv4 is not supported"
                }
                UnsupportedChannel::ChanToUdp64 => {
                    "Relaying channel IPv6 to UDPv4 is not supported"
                }
            },
            Error::XdpAdjustTailFailed(ret) => {
                // Handle this case separately to avoid complex control flow
                let mut written = 0;
                written += "Failed to adjust tail: ".write(buf)?.get();
                written += errno_to_str(ret).write(buf)?.get();
                return NonZeroUsize::new(written);
            }
        };

        msg.write(buf)
    }
}

impl aya_log_ebpf::macro_support::DefaultFormatter for Error {}

/// Helper function to map Linux/eBPF error codes to human-readable strings
/// This avoids integer formatting which can cause pointer arithmetic verifier issues
#[inline(always)]
fn errno_to_str(errno: i64) -> &'static str {
    match errno {
        -1 => "EPERM (Operation not permitted)",
        -2 => "ENOENT (No such file or directory)",
        -3 => "ESRCH (No such process)",
        -4 => "EINTR (Interrupted system call)",
        -5 => "EIO (I/O error)",
        -6 => "ENXIO (No such device or address)",
        -7 => "E2BIG (Argument list too long)",
        -8 => "ENOEXEC (Exec format error)",
        -9 => "EBADF (Bad file number)",
        -10 => "ECHILD (No child processes)",
        -11 => "EAGAIN (Try again)",
        -12 => "ENOMEM (Out of memory)",
        -13 => "EACCES (Permission denied)",
        -14 => "EFAULT (Bad address)",
        -16 => "EBUSY (Device or resource busy)",
        -17 => "EEXIST (File exists)",
        -19 => "ENODEV (No such device)",
        -22 => "EINVAL (Invalid argument)",
        -24 => "EMFILE (Too many open files)",
        -28 => "ENOSPC (No space left on device)",
        -32 => "EPIPE (Broken pipe)",
        -34 => "ERANGE (Math result not representable)",
        -61 => "ENODATA (No data available)",
        -75 => "EOVERFLOW (Value too large for defined data type)",
        -84 => "EILSEQ (Illegal byte sequence)",
        -90 => "EMSGSIZE (Message too long)",
        -95 => "ENOTSUP (Operation not supported)",
        -105 => "ENOBUFS (No buffer space available)",
        _ => "Unknown error",
    }
}
