use std::{io, os::fd::RawFd};

pub struct Tun(tun_apple::Io);

/// Finds the descriptor opened by NetworkExtension.
pub fn search_fd() -> io::Result<RawFd> {
    search_for_tun_fd()
}

impl Tun {
    /// Starts IO on the descriptor owned by NetworkExtension.
    ///
    /// # Safety
    ///
    /// The descriptor must remain open until the TUN IO and its workers have stopped.
    pub unsafe fn from_fd(fd: RawFd, runtime: &tokio::runtime::Handle) -> io::Result<Self> {
        let io = unsafe { tun_apple::Io::new(name(fd)?, fd, runtime)? };

        Ok(Self(io))
    }
}

impl tun::Tun for Tun {
    fn sender(&self) -> &tun::OutboundTx {
        self.0.sender()
    }
    fn receiver(&mut self) -> &mut tun::InboundRx {
        self.0.receiver()
    }
    fn name(&self) -> &str {
        self.0.name()
    }
}

fn get_last_error() -> io::Error {
    io::Error::last_os_error()
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn name(fd: RawFd) -> io::Result<String> {
    use libc::{IF_NAMESIZE, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, getsockopt, socklen_t};

    let mut tunnel_name = [0u8; IF_NAMESIZE];
    let mut tunnel_name_len = tunnel_name.len() as socklen_t;
    if unsafe {
        getsockopt(
            fd,
            SYSPROTO_CONTROL,
            UTUN_OPT_IFNAME,
            tunnel_name.as_mut_ptr() as _,
            &mut tunnel_name_len,
        )
    } < 0
        || tunnel_name_len == 0
    {
        return Err(get_last_error());
    }

    Ok(String::from_utf8_lossy(&tunnel_name[..(tunnel_name_len - 1) as usize]).to_string())
}

/// How many descriptors [`search_for_tun_fd`] may scan.
///
/// The utun descriptor's number depends on how many others the extension already
/// holds, so a fixed bound puts it out of reach once the process holds more than
/// that many. `RLIMIT_NOFILE` is the highest number the kernel can hand out, and
/// is what `getdtablesize` reports.
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn fd_table_size() -> RawFd {
    /// Applies when `getdtablesize` reports something unusable, and matches the
    /// bound the scan used before it consulted the limit at all.
    const FALLBACK: RawFd = 1024;

    // SAFETY: `getdtablesize` takes no arguments and only reads process state.
    let size = unsafe { libc::getdtablesize() };

    if size <= 0 { FALLBACK } else { size }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn search_for_tun_fd() -> io::Result<RawFd> {
    const CTL_NAME: &[u8] = b"com.apple.net.utun_control";

    use libc::{AF_SYSTEM, CTLIOCGINFO, ctl_info, getpeername, ioctl, sockaddr_ctl, socklen_t};
    use std::mem::size_of;

    let mut info = ctl_info {
        ctl_id: 0,
        ctl_name: [0; 96],
    };
    info.ctl_name[..CTL_NAME.len()]
        // SAFETY: We only care about maintaining the same byte value not the same value,
        // meaning that the slice &[u8] here is just a blob of bytes for us, we need this conversion
        // just because `c_char` is i8 (for some reason).
        // One thing I don't like about this is that `ctl_name` is actually a nul-terminated string,
        // which we are only getting because `CTRL_NAME` is less than 96 bytes long and we are 0-value
        // initializing the array we should be using a CStr to be explicit... but this is slightly easier.
        .copy_from_slice(unsafe { &*(CTL_NAME as *const [u8] as *const [i8]) });

    // On Apple platforms, we must use a NetworkExtension for reading and writing
    // packets if we want to be allowed in the iOS and macOS App Stores. This has the
    // unfortunate side effect that we're not allowed to create or destroy the tunnel
    // interface ourselves. The file descriptor should already be opened by the NetworkExtension for us
    // by this point. So instead, we iterate through all file descriptors looking for the one corresponding
    // to the utun interface we have access to read and write from.
    //
    // Credit to Jason Donenfeld (@zx2c4) for this technique. See docs/NOTICE.txt for attribution.
    // https://github.com/WireGuard/wireguard-apple/blob/master/Sources/WireGuardKit/WireGuardAdapter.swift
    for fd in 0..fd_table_size() {
        tracing::trace!("Checking fd {}", fd);

        // initialize empty sockaddr_ctl to be populated by getpeername
        let mut addr = sockaddr_ctl {
            sc_len: size_of::<sockaddr_ctl>() as u8,
            sc_family: 0,
            ss_sysaddr: 0,
            sc_id: info.ctl_id,
            sc_unit: 0,
            sc_reserved: Default::default(),
        };

        let mut len = size_of::<sockaddr_ctl>() as u32;
        let ret = unsafe {
            getpeername(
                fd,
                &mut addr as *mut sockaddr_ctl as _,
                &mut len as *mut socklen_t,
            )
        };
        if ret != 0 || addr.sc_family != AF_SYSTEM as u8 {
            continue;
        }

        if info.ctl_id == 0 {
            let ret = unsafe { ioctl(fd, CTLIOCGINFO, &mut info as *mut ctl_info) };

            if ret != 0 {
                continue;
            }
        }

        if addr.sc_id == info.ctl_id {
            return Ok(fd);
        }
    }

    // Not `get_last_error`: every miss above leaves `errno` set by the probe that
    // rejected the descriptor, so the final one describes whatever fd the scan
    // happened to end on rather than the search itself.
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "No utun file descriptor found",
    ))
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn search_for_tun_fd() -> io::Result<RawFd> {
    unimplemented!("Stub")
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn name(_: RawFd) -> io::Result<String> {
    unimplemented!("Stub")
}
