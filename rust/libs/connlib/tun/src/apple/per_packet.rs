//! Per-packet fallback I/O for the `utun` socket.
//!
//! Used when Apple's batched syscalls (`recvmsg_x` / `sendmsg_x`, see [`super::sys`])
//! are unavailable. Each datagram on the `utun` socket is prefixed with a 4-byte
//! address-family header; these plug into [`crate::unix::tun_send`] /
//! [`crate::unix::tun_recv`] as the per-packet `read` / `write` closures.

use ip_packet::{IpPacket, IpPacketBuf, IpVersion};
use libc::{AF_INET, AF_INET6, iovec, msghdr, recvmsg, sendmsg};
use std::io;
use std::os::fd::RawFd;

pub fn read(fd: RawFd, dst: &mut IpPacketBuf) -> io::Result<usize> {
    let dst = dst.buf();

    let mut hdr = [0u8; 4];

    let mut iov = [
        iovec {
            iov_base: hdr.as_mut_ptr() as _,
            iov_len: hdr.len(),
        },
        iovec {
            iov_base: dst.as_mut_ptr() as _,
            iov_len: dst.len(),
        },
    ];

    let mut msg_hdr = msghdr {
        msg_name: std::ptr::null_mut(),
        msg_namelen: 0,
        msg_iov: &mut iov[0],
        msg_iovlen: iov.len() as _,
        msg_control: std::ptr::null_mut(),
        msg_controllen: 0,
        msg_flags: 0,
    };

    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { recvmsg(fd, &mut msg_hdr, 0) } {
        -1 => Err(io::Error::last_os_error()),
        0..=4 => Ok(0),
        n => Ok((n - 4) as usize),
    }
}

pub fn write(fd: RawFd, src: &IpPacket) -> io::Result<usize> {
    let af = match src.version() {
        IpVersion::V4 => AF_INET,
        IpVersion::V6 => AF_INET6,
    };
    let src = src.packet();

    let mut hdr = [0, 0, 0, af];
    let mut iov = [
        iovec {
            iov_base: hdr.as_mut_ptr() as _,
            iov_len: hdr.len(),
        },
        iovec {
            iov_base: src.as_ptr() as _,
            iov_len: src.len(),
        },
    ];

    let msg_hdr = msghdr {
        msg_name: std::ptr::null_mut(),
        msg_namelen: 0,
        msg_iov: &mut iov[0],
        msg_iovlen: iov.len() as _,
        msg_control: std::ptr::null_mut(),
        msg_controllen: 0,
        msg_flags: 0,
    };

    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { sendmsg(fd, &msg_hdr, 0) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}
