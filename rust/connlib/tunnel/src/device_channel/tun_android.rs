use crate::device_channel::ioctl;
use crate::DnsFallbackStrategy;
use connlib_shared::{
    messages::Interface as InterfaceConfig, Callbacks, Error, Result, DNS_SENTINEL,
};
use ip_network::IpNetwork;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::{ready, Context, Poll};
use std::{
    io,
    os::fd::{AsRawFd, RawFd},
};
use tokio::io::unix::AsyncFd;
use tokio::io::Ready;

pub(crate) const SIOCGIFMTU: libc::c_ulong = libc::SIOCGIFMTU;

#[derive(Debug)]
pub(crate) struct Tun {
    fd: Closeable,
    name: String,
}

impl Drop for Tun {
    fn drop(&mut self) {
        unsafe { libc::close(self.fd.value.as_raw_fd()) };
    }
}

impl Tun {
    pub fn write4(&self, src: &[u8]) -> std::io::Result<usize> {
        self.fd.with(|fd| write(fd, src))?
    }

    pub fn write6(&self, src: &[u8]) -> std::io::Result<usize> {
        self.fd.with(|fd| write(fd, src))?
    }

    pub fn poll_read(&self, buf: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        self.fd.with(|fd| loop {
            let mut guard = ready!(fd.poll_read_ready(cx))?;

            match read(*guard.get_inner(), buf) {
                Ok(n) => return Poll::Ready(Ok(n)),
                Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                    // a read has blocked, but a write might still succeed.
                    // clear only the read readiness.
                    guard.clear_ready_matching(Ready::READABLE);
                    continue;
                }
                Err(e) => return Poll::Ready(Err(e)),
            }
        })?
    }

    pub fn close(&self) {
        self.fd.close();
    }

    pub fn new(
        config: &InterfaceConfig,
        callbacks: &impl Callbacks<Error = Error>,
        fallback_strategy: DnsFallbackStrategy,
    ) -> Result<Self> {
        let fd = callbacks
            .on_set_interface_config(
                config.ipv4,
                config.ipv6,
                DNS_SENTINEL,
                fallback_strategy.to_string(),
            )?
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

/// Read from the given file descriptor in the buffer.
fn read(fd: RawFd, dst: &mut [u8]) -> io::Result<usize> {
    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::read(fd, dst.as_mut_ptr() as _, dst.len()) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}

/// Write the buffer to the given file descriptor.
fn write(fd: impl AsRawFd, buf: &[u8]) -> io::Result<usize> {
    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::write(fd.as_raw_fd(), buf.as_ptr() as _, buf.len() as _) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}

#[derive(Debug)]
struct Closeable {
    closed: AtomicBool,
    value: AsyncFd<RawFd>,
}

impl Closeable {
    fn new(fd: AsyncFd<RawFd>) -> Self {
        Self {
            closed: AtomicBool::new(false),
            value: fd,
        }
    }

    fn with<U>(&self, f: impl FnOnce(AsyncFd<RawFd>) -> U) -> std::io::Result<U> {
        if self.closed.load(Ordering::Acquire) {
            return Err(std::io::Error::from_raw_os_error(9));
        }

        Ok(f(self.value))
    }

    fn close(&self) {
        self.closed.store(true, Ordering::Release);
    }
}
