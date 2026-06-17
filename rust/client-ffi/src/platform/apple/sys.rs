//! Bindings for Apple's private, batched socket syscalls `recvmsg_x` / `sendmsg_x`.
//!
//! These let us exchange multiple datagrams with the `utun` control socket in a
//! single syscall instead of one `recvmsg`/`sendmsg` per packet. They are not part
//! of the public SDK, so we resolve them at runtime via `dlsym` rather than link
//! against them. On all OS versions we support (macOS 13+, iOS 16+) they are
//! present, so resolution is expected to succeed; the `Option` return lets the
//! caller fall back to the per-packet path if it ever does not.

use std::ffi::{c_int, c_uint, c_void};
use std::io;
use std::os::fd::RawFd;
use std::sync::OnceLock;

/// Mirror of `struct msghdr_x` from XNU's `bsd/sys/socket_private.h`.
///
/// The layout matches the C definition on LP64 (the only ABI we build for on Apple).
/// Most fields are written by us and only ever read by the kernel through the
/// pointer we pass, so `dead_code` would flag them.
#[repr(C)]
#[derive(Clone, Copy)]
#[allow(dead_code)]
pub struct msghdr_x {
    /// Optional address; must be null for `sendmsg_x`.
    pub msg_name: *mut c_void,
    /// Size of the address.
    pub msg_namelen: libc::socklen_t,
    /// Scatter/gather array.
    pub msg_iov: *mut libc::iovec,
    /// Number of elements in `msg_iov`.
    pub msg_iovlen: c_int,
    /// Ancillary data; must be null for `sendmsg_x`.
    pub msg_control: *mut c_void,
    /// Ancillary data buffer length.
    pub msg_controllen: libc::socklen_t,
    /// Flags on the received message; must be zero on input.
    pub msg_flags: c_int,
    /// Byte length of the datagram; must be zero on input, set on output by `recvmsg_x`.
    pub msg_datalen: usize,
}

impl msghdr_x {
    pub const ZEROED: Self = msghdr_x {
        msg_name: std::ptr::null_mut(),
        msg_namelen: 0,
        msg_iov: std::ptr::null_mut(),
        msg_iovlen: 0,
        msg_control: std::ptr::null_mut(),
        msg_controllen: 0,
        msg_flags: 0,
        msg_datalen: 0,
    };
}

// `socket_private.h`: `ssize_t recvmsg_x(int, const struct msghdr_x *, u_int, int)`
// and `ssize_t sendmsg_x(int, const struct msghdr_x *, u_int, int)`. `recvmsg_x`
// writes the per-message out-fields (`msg_datalen`, `msg_flags`), hence `*mut`.
type RecvmsgX = unsafe extern "C" fn(RawFd, *mut msghdr_x, c_uint, c_int) -> isize;
type SendmsgX = unsafe extern "C" fn(RawFd, *const msghdr_x, c_uint, c_int) -> isize;

/// The resolved batched syscalls.
///
/// Both fields are plain function pointers into `libsystem`, so this is `Send + Sync`.
pub struct BatchSyscalls {
    recvmsg_x: RecvmsgX,
    sendmsg_x: SendmsgX,
}

/// Resolves `recvmsg_x` / `sendmsg_x` once, returning `None` if either is unavailable.
pub fn batch_syscalls() -> Option<&'static BatchSyscalls> {
    static SYSCALLS: OnceLock<Option<BatchSyscalls>> = OnceLock::new();

    SYSCALLS
        .get_or_init(|| {
            // Safety: `RTLD_DEFAULT` is a valid handle and the names are valid C strings.
            let recvmsg_x = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"recvmsg_x".as_ptr()) };
            let sendmsg_x = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"sendmsg_x".as_ptr()) };

            if recvmsg_x.is_null() || sendmsg_x.is_null() {
                return None;
            }

            Some(BatchSyscalls {
                // Safety: The symbols resolve to functions with the ABI declared above.
                recvmsg_x: unsafe { std::mem::transmute::<*mut c_void, RecvmsgX>(recvmsg_x) },
                sendmsg_x: unsafe { std::mem::transmute::<*mut c_void, SendmsgX>(sendmsg_x) },
            })
        })
        .as_ref()
}

impl BatchSyscalls {
    /// Receives up to `msgs.len()` datagrams, returning how many were received.
    ///
    /// # Safety
    ///
    /// `fd` must be valid and each `msghdr_x` must point to valid `iovec`s / buffers
    /// that live for the duration of the call.
    pub unsafe fn recvmsg_x(&self, fd: RawFd, msgs: &mut [msghdr_x]) -> io::Result<usize> {
        let n = unsafe { (self.recvmsg_x)(fd, msgs.as_mut_ptr(), msgs.len() as c_uint, 0) };

        if n < 0 {
            return Err(io::Error::last_os_error());
        }

        Ok(n as usize)
    }

    /// Sends up to `msgs.len()` datagrams, returning how many were sent.
    ///
    /// # Safety
    ///
    /// `fd` must be valid and each `msghdr_x` must point to valid `iovec`s / buffers
    /// that live for the duration of the call.
    pub unsafe fn sendmsg_x(&self, fd: RawFd, msgs: &[msghdr_x]) -> io::Result<usize> {
        let n = unsafe { (self.sendmsg_x)(fd, msgs.as_ptr(), msgs.len() as c_uint, 0) };

        if n < 0 {
            return Err(io::Error::last_os_error());
        }

        Ok(n as usize)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Locks in the `msghdr_x` layout against the C definition (LP64).
    #[test]
    fn msghdr_x_layout() {
        assert_eq!(size_of::<msghdr_x>(), 56);
        assert_eq!(std::mem::offset_of!(msghdr_x, msg_iov), 16);
        assert_eq!(std::mem::offset_of!(msghdr_x, msg_flags), 44);
        assert_eq!(std::mem::offset_of!(msghdr_x, msg_datalen), 48);
    }
}
