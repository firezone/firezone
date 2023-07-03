use ip_network::IpNetwork;
use libc::{
    close, connect, ctl_info, fcntl, getsockopt, ioctl, iovec, msghdr, recvmsg, sendmsg, sockaddr,
    sockaddr_ctl, sockaddr_in, socket, socklen_t, AF_INET, AF_INET6, AF_SYSTEM, AF_SYS_CONTROL,
    CTLIOCGINFO, F_GETFL, F_SETFL, IF_NAMESIZE, IPPROTO_IP, O_NONBLOCK, PF_SYSTEM, SOCK_DGRAM,
    SOCK_STREAM, SYSPROTO_CONTROL, UTUN_OPT_IFNAME,
};
use libs_common::{Error, Result};
use std::{
    ffi::{c_int, c_short, c_uchar},
    io,
    mem::{size_of, size_of_val},
    os::fd::{AsRawFd, RawFd},
    sync::Arc,
};

use super::InterfaceConfig;

const CTRL_NAME: &[u8] = b"com.apple.net.utun_control";
const SIOCGIFMTU: u64 = 0x0000_0000_c020_6933;

#[derive(Debug)]
pub(crate) struct IfaceConfig(pub(crate) Arc<IfaceDevice>);

#[derive(Debug)]
pub(crate) struct IfaceDevice {
    fd: RawFd,
}

impl AsRawFd for IfaceDevice {
    fn as_raw_fd(&self) -> RawFd {
        self.fd
    }
}

impl Drop for IfaceDevice {
    fn drop(&mut self) {
        unsafe { close(self.fd) };
    }
}
// For some reason this is not available in libc for darwin :c
#[allow(non_camel_case_types)]
#[repr(C)]
pub struct ifreq {
    ifr_name: [c_uchar; IF_NAMESIZE],
    ifr_ifru: IfrIfru,
}

#[repr(C)]
union IfrIfru {
    ifru_addr: sockaddr,
    ifru_addr_v4: sockaddr_in,
    ifru_addr_v6: sockaddr_in,
    ifru_dstaddr: sockaddr,
    ifru_broadaddr: sockaddr,
    ifru_flags: c_short,
    ifru_metric: c_int,
    ifru_mtu: c_int,
    ifru_phys: c_int,
    ifru_media: c_int,
    ifru_intval: c_int,
    ifru_wake_flags: u32,
    ifru_route_refcnt: u32,
    ifru_cap: [c_int; 2],
    ifru_functional_type: u32,
}

// On Darwin tunnel can only be named utunXXX
pub fn parse_utun_name(name: &str) -> Result<u32> {
    if !name.starts_with("utun") {
        return Err(Error::InvalidTunnelName);
    }

    match name.get(4..) {
        None | Some("") => {
            // The name is simply "utun"
            Ok(0)
        }
        Some(idx) => {
            // Everything past utun should represent an integer index
            idx.parse::<u32>()
                .map_err(|_| Error::InvalidTunnelName)
                .map(|x| x + 1)
        }
    }
}

impl IfaceDevice {
    fn write(&self, src: &[u8], af: u8) -> usize {
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

        match unsafe { sendmsg(self.fd, &msg_hdr, 0) } {
            -1 => 0,
            n => n as usize,
        }
    }

    pub async fn new(name: &str) -> Result<Self> {
        let idx = parse_utun_name(name)?;

        let fd = match unsafe { socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL) } {
            -1 => return Err(get_last_error()),
            fd => fd,
        };

        let mut info = ctl_info {
            ctl_id: 0,
            ctl_name: [0; 96],
        };
        info.ctl_name[..CTRL_NAME.len()]
            // SAFETY: We only care about maintaining the same byte value not the same value,
            // meaning that the slice &[u8] here is just a blob of bytes for us, we need this conversion
            // just because `c_char` is i8 (for some reason).
            // One thing I don't like about this is that `ctl_name` is actually a nul-terminated string,
            // which we are only getting because `CTRL_NAME` is less than 96 bytes long and we are 0-value
            // initializing the array we should be using a CStr to be explicit... but this is slightly easier.
            .copy_from_slice(unsafe { &*(CTRL_NAME as *const [u8] as *const [i8]) });

        if unsafe { ioctl(fd, CTLIOCGINFO, &mut info as *mut ctl_info) } < 0 {
            unsafe { close(fd) };
            return Err(get_last_error());
        }

        let addr = sockaddr_ctl {
            sc_len: size_of::<sockaddr_ctl>() as u8,
            sc_family: AF_SYSTEM as u8,
            ss_sysaddr: AF_SYS_CONTROL as u16,
            sc_id: info.ctl_id,
            sc_unit: idx,
            sc_reserved: Default::default(),
        };

        if unsafe {
            connect(
                fd,
                &addr as *const sockaddr_ctl as _,
                size_of_val(&addr) as _,
            )
        } < 0
        {
            unsafe { close(fd) };
            return Err(get_last_error());
        }

        Ok(Self { fd })
    }

    pub fn set_non_blocking(self) -> Result<Self> {
        match unsafe { fcntl(self.fd, F_GETFL) } {
            -1 => Err(get_last_error()),
            flags => match unsafe { fcntl(self.fd, F_SETFL, flags | O_NONBLOCK) } {
                -1 => Err(get_last_error()),
                _ => Ok(self),
            },
        }
    }

    pub fn name(&self) -> Result<String> {
        let mut tunnel_name = [0u8; 256];
        let mut tunnel_name_len = tunnel_name.len() as socklen_t;
        if unsafe {
            getsockopt(
                self.fd,
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

    /// Get the current MTU value
    pub async fn mtu(&self) -> Result<usize> {
        let fd = match unsafe { socket(AF_INET, SOCK_STREAM, IPPROTO_IP) } {
            -1 => return Err(get_last_error()),
            fd => fd,
        };

        let name = self.name()?;
        let iface_name: &[u8] = name.as_ref();
        let mut ifr = ifreq {
            ifr_name: [0; IF_NAMESIZE],
            ifr_ifru: IfrIfru { ifru_mtu: 0 },
        };

        ifr.ifr_name[..iface_name.len()].copy_from_slice(iface_name);

        if unsafe { ioctl(fd, SIOCGIFMTU, &ifr) } < 0 {
            return Err(get_last_error());
        }

        unsafe { close(fd) };

        Ok(unsafe { ifr.ifr_ifru.ifru_mtu } as _)
    }

    pub fn write4(&self, src: &[u8]) -> usize {
        self.write(src, AF_INET as u8)
    }

    pub fn write6(&self, src: &[u8]) -> usize {
        self.write(src, AF_INET6 as u8)
    }

    pub fn read<'a>(&self, dst: &'a mut [u8]) -> Result<&'a mut [u8]> {
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

        match unsafe { recvmsg(self.fd, &mut msg_hdr, 0) } {
            -1 => Err(Error::IfaceRead(io::Error::last_os_error())),
            0..=4 => Ok(&mut dst[..0]),
            n => Ok(&mut dst[..(n - 4) as usize]),
        }
    }
}

// So, these functions take a mutable &self, this is not necessary in theory but it's correct!
impl IfaceConfig {
    pub async fn add_route(&mut self, route: &IpNetwork) -> Result<()> {
        tracing::error!("`add_route` unimplemented on macOS: `{route:#?}`");
        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_iface_config(&mut self, config: &InterfaceConfig) -> Result<()> {
        tracing::error!("`set_iface_config` unimplemented on macOS: `{config:#?}`");
        Ok(())
    }

    pub async fn up(&mut self) -> Result<()> {
        tracing::error!("`up` unimplemented on macOS");
        Ok(())
    }
}

fn get_last_error() -> Error {
    Error::Io(io::Error::last_os_error())
}
