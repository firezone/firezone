use crate::device_channel::ioctl;
use connlib_shared::{messages::Interface as InterfaceConfig, Callbacks, Error, Result};
use ip_network::IpNetwork;
use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::{Context, Poll};
use std::{
    io,
    os::fd::{AsRawFd, RawFd},
};
use tokio::io::unix::AsyncFd;

mod utils;

pub(crate) const SIOCGIFMTU: libc::c_ulong = libc::SIOCGIFMTU;

#[derive(Debug)]
pub(crate) struct Tun {
    fd: Closeable,
    name: String,
}

impl Drop for Tun {
    fn drop(&mut self) {
        unsafe { libc::close(self.fd.fd.as_raw_fd()) };
    }
}

impl Tun {
    pub fn write4(&self, src: &[u8]) -> std::io::Result<usize> {
        self.fd.with(|fd| write(*fd.get_ref(), src))?
    }

    pub fn write6(&self, src: &[u8]) -> std::io::Result<usize> {
        self.fd.with(|fd| write(*fd.get_ref(), src))?
    }

    pub fn poll_read(&self, buf: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        self.fd
            .with(|fd| utils::poll_raw_fd(&fd, |fd| read(fd, buf), cx))?
    }

    pub fn new(
        config: &InterfaceConfig,
        dns_config: Vec<IpAddr>,
        callbacks: &impl Callbacks<Error = Error>,
    ) -> Result<Self> {
        let fd = callbacks
            .on_set_interface_config(config.ipv4, config.ipv6, dns_config)?
            .ok_or(Error::NoFd)?;
        // Safety: File descriptor is open.
        let name = unsafe { interface_name(fd)? };

        Ok(Tun {
            fd: Closeable::new(AsyncFd::new(fd)?),
            name,
        })
    }

    pub fn name(&self) -> &str {
        self.name.as_str()
    }

    pub fn add_route(
        &self,
        route: IpNetwork,
        callbacks: &impl Callbacks<Error = Error>,
    ) -> Result<Option<Self>> {
        self.fd.close();
        let fd = callbacks.on_add_route(route)?.ok_or(Error::NoFd)?;
        let name = unsafe { interface_name(fd)? };

        Ok(Some(Tun {
            fd: Closeable::new(AsyncFd::new(fd)?),
            name,
        }))
    }

    pub fn remove_route(
        &self,
        route: IpNetwork,
        callbacks: &impl Callbacks<Error = Error>,
    ) -> Result<Option<Self>> {
        self.fd.close();
        let fd = callbacks.on_remove_route(route)?.ok_or(Error::NoFd)?;
        let name = unsafe { interface_name(fd)? };

        Ok(Some(Tun {
            fd: Closeable::new(AsyncFd::new(fd)?),
            name,
        }))
    }
}

/// Retrieves the name of the interface pointed to by the provided file descriptor.
///
/// # Safety
///
/// The file descriptor must be open.
unsafe fn interface_name(fd: RawFd) -> Result<String> {
    const TUNGETIFF: libc::c_ulong = 0x800454d2;
    let mut request = ioctl::Request::<GetInterfaceNamePayload>::new();

    ioctl::exec(fd, TUNGETIFF, &mut request)?;

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
struct GetInterfaceNamePayload {
    // Fixes a nasty alignment bug on 32-bit architectures on Android.
    // The `name` field in `ioctl::Request` is only 16 bytes long and accessing it causes a NPE without this alignment.
    // Why? Not sure. It seems to only happen in release mode which hints at an optimisation issue.
    alignment: [std::ffi::c_uchar; 16],
}

/// Read from the given file descriptor in the buffer.
fn read(fd: RawFd, dst: &mut [u8]) -> io::Result<usize> {
    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::read(fd, dst.as_mut_ptr() as _, dst.len()) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}

/// Write the buffer to the given file descriptor.
fn write(fd: RawFd, buf: &[u8]) -> io::Result<usize> {
    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::write(fd.as_raw_fd(), buf.as_ptr() as _, buf.len() as _) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}

#[derive(Debug)]
struct Closeable {
    closed: AtomicBool,
    fd: AsyncFd<RawFd>,
}

impl Closeable {
    fn new(fd: AsyncFd<RawFd>) -> Self {
        Self {
            closed: AtomicBool::new(false),
            fd,
        }
    }

    fn with<U>(&self, f: impl FnOnce(&AsyncFd<RawFd>) -> U) -> std::io::Result<U> {
        if self.closed.load(Ordering::Acquire) {
            return Err(std::io::Error::from_raw_os_error(9));
        }

        Ok(f(&self.fd))
    }

    fn close(&self) {
        self.closed.store(true, Ordering::Release);
    }
}
