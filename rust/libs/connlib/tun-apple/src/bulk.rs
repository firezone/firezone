//! Bulk TUN I/O using Apple's `recvmsg_x` / `sendmsg_x` (see [`super::sys`]).
//!
//! These exchange a whole batch of packets with the `utun` socket per syscall. The read side is the
//! bigger win: the kernel dequeues the batch under a single lock and only runs its
//! flow-control hand-off once per batch instead of once per packet.

use ip_packet::{IpPacket, IpPacketBuf, IpVersion};
use libc::{AF_INET, AF_INET6, iovec};
use std::ffi::c_void;
use std::io;
use std::os::fd::RawFd;

use super::sys;
use tun::MAX_BATCH_SIZE;

const EMPTY_IOVEC: iovec = iovec {
    iov_base: std::ptr::null_mut(),
    iov_len: 0,
};

/// Writes `batch` to `fd` in one `sendmsg_x`, returning the number of packets sent.
///
/// # Safety
///
/// `fd` must be a valid, open `utun` file descriptor.
pub(super) unsafe fn send_batch(
    syscalls: &sys::BatchSyscalls,
    fd: RawFd,
    batch: &[IpPacket],
) -> io::Result<usize> {
    let count = batch.len().min(MAX_BATCH_SIZE);

    // The first 4 bytes of each datagram carry the address family in network byte order.
    let mut afs = [[0u8; 4]; MAX_BATCH_SIZE];
    let mut iovs = [[EMPTY_IOVEC; 2]; MAX_BATCH_SIZE];
    let mut msgs = [sys::msghdr_x::ZEROED; MAX_BATCH_SIZE];

    for i in 0..count {
        #[cfg(debug_assertions)]
        tracing::trace!(target: "wire::dev::send", packet = ?batch[i]);

        let af = match batch[i].version() {
            IpVersion::V4 => AF_INET,
            IpVersion::V6 => AF_INET6,
        };
        afs[i] = (af as u32).to_be_bytes();

        let payload = batch[i].packet();
        iovs[i] = [
            iovec {
                iov_base: afs[i].as_ptr() as *mut c_void,
                iov_len: afs[i].len(),
            },
            iovec {
                iov_base: payload.as_ptr() as *mut c_void,
                iov_len: payload.len(),
            },
        ];
        msgs[i] = sys::msghdr_x {
            msg_iov: iovs[i].as_mut_ptr(),
            msg_iovlen: 2,
            ..sys::msghdr_x::ZEROED
        };
    }

    // Safety: `msgs[..count]` point at `iovs` / `afs` / packet payloads, all of which
    // outlive this call.
    unsafe { syscalls.sendmsg_x(fd, &msgs[..count]) }
}

/// Reads up to `bufs.len()` packets from `fd` in one `recvmsg_x`.
///
/// Writes each packet's length (with the 4-byte address-family header stripped) into
/// `lens` and returns the number of packets read. A length of `0` marks a slot that
/// should be skipped.
///
/// # Safety
///
/// `fd` must be a valid, open `utun` file descriptor.
pub(super) unsafe fn recv_batch(
    syscalls: &sys::BatchSyscalls,
    fd: RawFd,
    bufs: &mut [IpPacketBuf],
    lens: &mut [usize],
) -> io::Result<usize> {
    let count = bufs.len().min(MAX_BATCH_SIZE);

    let mut afs = [[0u8; 4]; MAX_BATCH_SIZE];
    let mut iovs = [[EMPTY_IOVEC; 2]; MAX_BATCH_SIZE];
    let mut msgs = [sys::msghdr_x::ZEROED; MAX_BATCH_SIZE];

    for i in 0..count {
        let dst = bufs[i].buf();
        iovs[i] = [
            iovec {
                iov_base: afs[i].as_mut_ptr() as *mut c_void,
                iov_len: afs[i].len(),
            },
            iovec {
                iov_base: dst.as_mut_ptr() as *mut c_void,
                iov_len: dst.len(),
            },
        ];
        msgs[i] = sys::msghdr_x {
            msg_iov: iovs[i].as_mut_ptr(),
            msg_iovlen: 2,
            ..sys::msghdr_x::ZEROED
        };
    }

    // Safety: `msgs[..count]` point at `iovs` / `afs` / the buffers in `bufs`, all of
    // which outlive this call.
    let n = unsafe { syscalls.recvmsg_x(fd, &mut msgs[..count])? };

    for i in 0..n {
        // A truncated datagram cannot happen at our MTU (each buffer holds 4 + `MAX_IP_SIZE`
        // bytes), but guard against it anyway by skipping the slot.
        lens[i] = if msgs[i].msg_flags & libc::MSG_TRUNC != 0 {
            0
        } else {
            // `msg_datalen` includes the 4-byte address-family header.
            msgs[i].msg_datalen.saturating_sub(4)
        };
    }

    Ok(n)
}
