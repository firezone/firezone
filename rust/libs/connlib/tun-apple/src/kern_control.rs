//! Mirrors of XNU's `bsd/sys/kern_control.h` and `bsd/sys/sys_domain.h`.
//!
//! The kernel supports these on every Apple OS, but only the macOS SDK ships the
//! headers, so `libc` exposes them on macOS alone.

use std::ffi::{c_char, c_int, c_ulong};

pub const AF_SYS_CONTROL: c_int = 2;
pub const SYSPROTO_CONTROL: c_int = 2;

const MAX_KCTL_NAME: usize = 96;

/// `_IOWR('N', 3, struct ctl_info)`.
pub const CTLIOCGINFO: c_ulong = 0xc0644e03;

#[repr(C)]
pub struct ctl_info {
    pub ctl_id: u32,
    pub ctl_name: [c_char; MAX_KCTL_NAME],
}

#[repr(C)]
pub struct sockaddr_ctl {
    pub sc_len: u8,
    pub sc_family: u8,
    pub ss_sysaddr: u16,
    pub sc_id: u32,
    pub sc_unit: u32,
    pub sc_reserved: [u32; 5],
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout() {
        assert_eq!(size_of::<ctl_info>(), 100);
        assert_eq!(size_of::<sockaddr_ctl>(), 32);
    }
}
