use super::InterfaceConfig;
use ip_network::IpNetwork;
use libc::{
    close, ioctl, read, sockaddr, sockaddr_in, write, AF_INET, IFNAMSIZ, IPPROTO_IP, SIOCGIFMTU,
    SOCK_STREAM,
};
use libs_common::{CallbackErrorFacade, Callbacks, Error, Result, DNS_SENTINEL};
use std::{
    ffi::{c_int, c_short, c_uchar},
    io,
    os::fd::{AsRawFd, RawFd},
    sync::Arc,
};

mod wrapped_socket;
// Android doesn't support Split DNS. So we intercept all requests and forward
// the non-Firezone name resolution requests to the upstream DNS resolver.
const DNS_FALLBACK_STRATEGY: &str = "upstream_resolver";

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

#[repr(C)]
pub struct ifreq {
    ifr_name: [c_uchar; IFNAMSIZ],
    ifr_ifru: IfrIfru,
}

const TUNGETIFF: u64 = 0x800454d2;

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

impl IfaceDevice {
    fn write(&self, buf: &[u8]) -> usize {
        match unsafe { write(self.fd, buf.as_ptr() as _, buf.len() as _) } {
            -1 => 0,
            n => n as usize,
        }
    }

    pub async fn new(
        config: &InterfaceConfig,
        callbacks: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<Self> {
        let fd = callbacks.on_set_interface_config(
            config.ipv4,
            config.ipv6,
            DNS_SENTINEL,
            DNS_FALLBACK_STRATEGY.to_string(),
        )?;
        Ok(Self { fd })
    }

    pub fn name(&self) -> Result<String> {
        let mut ifr = ifreq {
            ifr_name: [0; IFNAMSIZ],
            ifr_ifru: unsafe { std::mem::zeroed() },
        };

        match unsafe { ioctl(self.fd, TUNGETIFF as _, &mut ifr) } {
            0 => {
                let name_cstr = unsafe { std::ffi::CStr::from_ptr(ifr.ifr_name.as_ptr() as _) };
                Ok(name_cstr.to_string_lossy().into_owned())
            }
            _ => Err(get_last_error()),
        }
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
            ifr_name: [0; IFNAMSIZ],
            ifr_ifru: IfrIfru { ifru_mtu: 0 },
        };

        ifr.ifr_name[..iface_name.len()].copy_from_slice(iface_name);

        if unsafe { ioctl(fd, SIOCGIFMTU as _, &ifr) } < 0 {
            return Err(get_last_error());
        }

        let mtu = unsafe { ifr.ifr_ifru.ifru_mtu };

        tracing::debug!("MTU for {} is {}", name, mtu);
        Ok(mtu as _)
    }

    pub fn write4(&self, src: &[u8]) -> usize {
        self.write(src)
    }

    pub fn write6(&self, src: &[u8]) -> usize {
        self.write(src)
    }

    pub fn read<'a>(&self, dst: &'a mut [u8]) -> Result<&'a mut [u8]> {
        match unsafe { read(self.fd, dst.as_mut_ptr() as _, dst.len()) } {
            -1 => Err(Error::IfaceRead(io::Error::last_os_error())),
            n => Ok(&mut dst[..n as usize]),
        }
    }
}

fn get_last_error() -> Error {
    Error::Io(io::Error::last_os_error())
}

impl IfaceConfig {
    pub async fn add_route(
        &mut self,
        route: IpNetwork,
        callbacks: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<()> {
        callbacks.on_add_route(route)
    }

    pub async fn up(&mut self) -> Result<()> {
        tracing::debug!("`up` unimplemented on Android");
        Ok(())
    }
}
