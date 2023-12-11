use crate::device_channel::ioctl;
use closeable::Closeable;
use connlib_shared::{
    messages::Interface as InterfaceConfig, Callbacks, Error, Result, DNS_SENTINEL,
};
use ip_network::IpNetwork;
use libc::{
    close, ioctl, read, sockaddr, sockaddr_in, write, AF_INET, IFNAMSIZ, IPPROTO_IP, SOCK_STREAM,
};
use std::{
    ffi::{c_int, c_short, c_uchar},
    io,
    os::fd::{AsRawFd, RawFd},
    sync::Arc,
};
use tokio::io::unix::AsyncFd;

mod closeable;

pub(crate) const SIOCGIFMTU: libc::c_ulong = libc::SIOCGIFMTU;

// Android doesn't support Split DNS. So we intercept all requests and forward
// the non-Firezone name resolution requests to the upstream DNS resolver.
const DNS_FALLBACK_STRATEGY: &str = "upstream_resolver";

#[derive(Debug)]
pub(crate) struct Tun {
    fd: Closeable,
    name: String,
}

impl AsRawFd for Tun {
    fn as_raw_fd(&self) -> RawFd {
        self.fd.as_raw_fd()
    }
}

impl Drop for Tun {
    fn drop(&mut self) {
        unsafe { close(self.fd.as_raw_fd()) };
    }
}

impl Tun {
    fn write(&self, buf: &[u8]) -> std::io::Result<usize> {
        match self
            .fd
            .with(|fd| unsafe { write(fd, buf.as_ptr() as _, buf.len() as _) })?
        {
            -1 => Err(io::Error::last_os_error()),
            n => Ok(n as usize),
        }
    }

    pub fn write4(&self, src: &[u8]) -> std::io::Result<usize> {
        self.write(src)
    }

    pub fn write6(&self, src: &[u8]) -> std::io::Result<usize> {
        self.write(src)
    }

    pub fn read(&self, dst: &mut [u8]) -> std::io::Result<usize> {
        // We don't read(or write) again from the fd because the given fd number might be reclaimed
        // so this could make an spurious read/write to another fd and we DEFINITELY don't want that
        match self
            .fd
            .with(|fd| unsafe { read(fd, dst.as_mut_ptr() as _, dst.len()) })?
        {
            -1 => Err(io::Error::last_os_error()),
            n => Ok(n as usize),
        }
    }

    pub fn close(&self) {
        self.fd.close();
    }
}

impl Tun {
    pub async fn new(
        config: &InterfaceConfig,
        callbacks: &impl Callbacks<Error = Error>,
    ) -> Result<Self> {
        let fd = callbacks
            .on_set_interface_config(
                config.ipv4,
                config.ipv6,
                DNS_SENTINEL,
                DNS_FALLBACK_STRATEGY.to_string(),
            )?
            .ok_or(Error::NoFd)?;
        // Safety: File descriptor is open.
        let name = unsafe { interface_name(fd)? };

        Ok(Tun {
            fd: Closeable::new(fd.into()),
            name,
        })
    }

    pub fn name(&self) -> &str {
        self.name.as_str()
    }

    pub async fn add_route(
        &self,
        route: IpNetwork,
        callbacks: &impl Callbacks<Error = Error>,
    ) -> Result<Option<Self>> {
        self.fd.close();
        let fd = callbacks.on_add_route(route)?.ok_or(Error::NoFd)?;
        let name = unsafe { interface_name(fd)? };

        Ok(Some(Tun {
            fd: Closeable::new(fd.into()),
            name,
        }))
    }

    pub async fn up(&self) -> Result<()> {
        Ok(())
    }
}

/// Retrieves the name of the interface pointed to by the provided file descriptor.
///
/// # Safety
///
/// The file descriptor must be open.
unsafe fn interface_name(fd: RawFd) -> Result<String> {
    const TUNGETIFF: libc::c_ulong = 0x800454d2;
    let request = ioctl::Request::<GetInterfaceNamePayload>::new();

    ioctl::exec(fd, TUNGETIFF, &request)?;

    Ok(request.name().to_string())
}

impl ioctl::Request<GetInterfaceNamePayload> {
    fn new() -> Self {
        Self {
            name: [0u8; libc::IF_NAMESIZE],
            payload: Default::default(),
        }
    }

    fn name(&self) -> std::borrow::Cow<'_, str> {
        // Safety: The memory of `self.name` is always initialized.
        let cstr = unsafe { std::ffi::CStr::from_ptr(self.name.as_ptr() as _) };

        cstr.to_string_lossy()
    }
}

#[derive(Default)]
#[repr(C)]
struct GetInterfaceNamePayload;
