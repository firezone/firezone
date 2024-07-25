use std::task::{Context, Poll};
use std::{
    io,
    os::fd::{AsRawFd, RawFd},
};
use tokio::io::unix::AsyncFd;
use tun::ioctl;

#[derive(Debug)]
pub struct Tun {
    fd: AsyncFd<RawFd>,
    name: String,
}

impl Drop for Tun {
    fn drop(&mut self) {
        unsafe { libc::close(self.fd.as_raw_fd()) };
    }
}

impl tun::Tun for Tun {
    fn write4(&self, src: &[u8]) -> std::io::Result<usize> {
        write(self.fd.as_raw_fd(), src)
    }

    fn write6(&self, src: &[u8]) -> std::io::Result<usize> {
        write(self.fd.as_raw_fd(), src)
    }

    fn poll_read(&mut self, buf: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        tun::unix::poll_raw_fd(&self.fd, |fd| read(fd, buf), cx)
    }

    fn name(&self) -> &str {
        self.name.as_str()
    }
}

impl Tun {
    /// Create a new [`Tun`] from a raw file descriptor.
    ///
    /// # Safety
    ///
    /// The file descriptor must be open.
    pub unsafe fn from_fd(fd: RawFd) -> io::Result<Self> {
        let name = interface_name(fd)?;

        Ok(Tun {
            fd: AsyncFd::new(fd)?,
            name,
        })
    }
}

/// Retrieves the name of the interface pointed to by the provided file descriptor.
///
/// # Safety
///
/// The file descriptor must be open.
unsafe fn interface_name(fd: RawFd) -> io::Result<String> {
    const TUNGETIFF: libc::c_ulong = 0x800454d2;
    let mut request = tun::ioctl::Request::<tun::ioctl::GetInterfaceNamePayload>::new();

    ioctl::exec(fd, TUNGETIFF, &mut request)?;

    Ok(request.name().to_string())
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
