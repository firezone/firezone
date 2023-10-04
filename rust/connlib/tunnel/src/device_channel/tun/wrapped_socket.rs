use libc::{close, socket};
use std::ffi::c_int;
use std::os::fd::RawFd;

pub struct WrappedSocket {
    fd: RawFd,
}

impl WrappedSocket {
    pub fn new(domain: c_int, sock_type: c_int, protocol: c_int) -> Self {
        let fd = unsafe { socket(domain, sock_type, protocol) };
        Self { fd }
    }

    pub fn as_raw_fd(&self) -> RawFd {
        self.fd
    }
}

impl Drop for WrappedSocket {
    fn drop(&mut self) {
        if self.fd == -1 {
            return;
        }

        unsafe { close(self.fd) };
    }
}
