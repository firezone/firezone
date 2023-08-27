use ip_network::IpNetwork;
use libc::{
    close, ctl_info, fcntl, getpeername, getsockopt, ioctl, iovec, msghdr, recvmsg, sendmsg,
    sockaddr, sockaddr_ctl, sockaddr_in, socklen_t, AF_INET, AF_INET6, AF_SYSTEM, CTLIOCGINFO,
    F_GETFL, F_SETFL, IF_NAMESIZE, IPPROTO_IP, O_NONBLOCK, SOCK_STREAM, SYSPROTO_CONTROL,
    UTUN_OPT_IFNAME,
};
use libs_common::{CallbackErrorFacade, Callbacks, Error, Result, DNS_SENTINEL};
use std::{
    ffi::{c_int, c_short, c_uchar},
    io,
    mem::size_of,
    os::fd::{AsRawFd, RawFd},
    sync::Arc,
};

use super::InterfaceConfig;

const CTL_NAME: &[u8] = b"com.apple.net.utun_control";
const SIOCGIFMTU: u64 = 0x0000_0000_c020_6933;

#[derive(Debug)]
pub(crate) struct IfaceConfig(pub(crate) Arc<IfaceDevice>);

#[derive(Debug)]
pub(crate) struct IfaceDevice {
    fd: RawFd,
}

mod wrapped_socket;

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

    pub async fn new(
        config: &InterfaceConfig,
        callbacks: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<Self> {
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
        // Credit to Jason Donenfeld (@zx2c4) for this technique. See NOTICE.txt for attribution.
        // https://github.com/WireGuard/wireguard-apple/blob/master/Sources/WireGuardKit/WireGuardAdapter.swift
        for fd in 0..1024 {
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
                let _ = callbacks.on_set_interface_config(
                    config.ipv4,
                    config.ipv6,
                    DNS_SENTINEL,
                    "system_resolver".to_string(),
                );
                let this = Self { fd };
                let _ = this.set_non_blocking();
                return Ok(this);
            }
        }

        Err(get_last_error())
    }

    fn set_non_blocking(&self) -> Result<()> {
        match unsafe { fcntl(self.fd, F_GETFL) } {
            -1 => Err(get_last_error()),
            flags => match unsafe { fcntl(self.fd, F_SETFL, flags | O_NONBLOCK) } {
                -1 => Err(get_last_error()),
                _ => Ok(()),
            },
        }
    }

    pub fn name(&self) -> Result<String> {
        let mut tunnel_name = [0u8; IF_NAMESIZE];
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
        let socket = wrapped_socket::WrappedSocket::new(AF_INET, SOCK_STREAM, IPPROTO_IP);
        let fd = match socket.as_raw_fd() {
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

        let mtu = unsafe { ifr.ifr_ifru.ifru_mtu };

        tracing::debug!("MTU for {} is {}", name, mtu);
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
    pub async fn add_route(
        &mut self,
        route: IpNetwork,
        callbacks: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<()> {
        callbacks.on_add_route(route)
    }

    pub async fn up(&mut self) -> Result<()> {
        tracing::info!("`up` unimplemented on macOS");
        Ok(())
    }
}

fn get_last_error() -> Error {
    Error::Io(io::Error::last_os_error())
}
