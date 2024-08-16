// Copyright (c) 2019 Cloudflare, Inc. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

use super::Error;
use libc::*;
use std::io;
use std::mem::size_of;
use std::mem::size_of_val;
use std::os::unix::io::{AsRawFd, RawFd};
use std::ptr::null_mut;

const CTRL_NAME: &[u8] = b"com.apple.net.utun_control";

#[repr(C)]
pub struct ctl_info {
    pub ctl_id: u32,
    pub ctl_name: [c_uchar; 96],
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
    //ifru_data: caddr_t,
    //ifru_devmtu: ifdevmtu,
    //ifru_kpi: ifkpi,
    ifru_wake_flags: u32,
    ifru_route_refcnt: u32,
    ifru_cap: [c_int; 2],
    ifru_functional_type: u32,
}

#[repr(C)]
pub struct ifreq {
    ifr_name: [c_uchar; IF_NAMESIZE],
    ifr_ifru: IfrIfru,
}

const CTLIOCGINFO: u64 = 0x0000_0000_c064_4e03;
const SIOCGIFMTU: u64 = 0x0000_0000_c020_6933;

#[derive(Default, Debug)]
pub struct TunSocket {
    fd: RawFd,
}

impl Drop for TunSocket {
    fn drop(&mut self) {
        unsafe { close(self.fd) };
    }
}

impl AsRawFd for TunSocket {
    fn as_raw_fd(&self) -> RawFd {
        self.fd
    }
}

// On Darwin tunnel can only be named utunXXX
pub fn parse_utun_name(name: &str) -> Result<u32, Error> {
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

impl TunSocket {
    fn write(&self, src: &[u8], af: u8) -> usize {
        let mut hdr = [0u8, 0u8, 0u8, af as u8];
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
            msg_name: null_mut(),
            msg_namelen: 0,
            msg_iov: &mut iov[0],
            msg_iovlen: iov.len() as _,
            msg_control: null_mut(),
            msg_controllen: 0,
            msg_flags: 0,
        };

        match unsafe { sendmsg(self.fd, &msg_hdr, 0) } {
            -1 => 0,
            n => n as usize,
        }
    }

    pub fn new(name: &str) -> Result<TunSocket, Error> {
        let idx = parse_utun_name(name)?;

        let fd = match unsafe { socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL) } {
            -1 => return Err(Error::Socket(io::Error::last_os_error())),
            fd => fd,
        };

        let mut info = ctl_info {
            ctl_id: 0,
            ctl_name: [0u8; 96],
        };
        info.ctl_name[..CTRL_NAME.len()].copy_from_slice(CTRL_NAME);

        if unsafe { ioctl(fd, CTLIOCGINFO, &mut info as *mut ctl_info) } < 0 {
            unsafe { close(fd) };
            return Err(Error::IOCtl(io::Error::last_os_error()));
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
            let mut err_string = io::Error::last_os_error().to_string();
            err_string.push_str("(did you run with sudo?)");
            return Err(Error::Connect(err_string));
        }

        Ok(TunSocket { fd })
    }

    pub fn set_non_blocking(self) -> Result<TunSocket, Error> {
        match unsafe { fcntl(self.fd, F_GETFL) } {
            -1 => Err(Error::FCntl(io::Error::last_os_error())),
            flags => match unsafe { fcntl(self.fd, F_SETFL, flags | O_NONBLOCK) } {
                -1 => Err(Error::FCntl(io::Error::last_os_error())),
                _ => Ok(self),
            },
        }
    }

    pub fn name(&self) -> Result<String, Error> {
        let mut tunnel_name = [0u8; 256];
        let mut tunnel_name_len: socklen_t = tunnel_name.len() as u32;
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
            return Err(Error::GetSockOpt(io::Error::last_os_error()));
        }

        Ok(String::from_utf8_lossy(&tunnel_name[..(tunnel_name_len - 1) as usize]).to_string())
    }

    /// Get the current MTU value
    pub fn mtu(&self) -> Result<usize, Error> {
        let fd = match unsafe { socket(AF_INET, SOCK_STREAM, IPPROTO_IP) } {
            -1 => return Err(Error::Socket(io::Error::last_os_error())),
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
            return Err(Error::IOCtl(io::Error::last_os_error()));
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

    pub fn read<'a>(&self, dst: &'a mut [u8]) -> Result<&'a mut [u8], Error> {
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
            msg_name: null_mut(),
            msg_namelen: 0,
            msg_iov: &mut iov[0],
            msg_iovlen: iov.len() as _,
            msg_control: null_mut(),
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
