use std::{
    io,
    os::fd::{AsRawFd as _, FromRawFd, OwnedFd, RawFd},
};
use tun::ioctl;

pub struct Tun {
    name: String,
    fd: OwnedFd,
}

impl tun::Tun for Tun {
    fn into_io(self: Box<Self>) -> tun::TunIo {
        tun::TunIo::Android(self.fd)
    }

    fn name(&self) -> &str {
        &self.name
    }
}

impl Tun {
    /// Takes ownership of the TUN descriptor supplied by `VpnService`.
    ///
    /// # Safety
    ///
    /// The descriptor must be open and its ownership must be transferred to this function.
    pub unsafe fn from_fd(fd: RawFd) -> io::Result<Self> {
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };
        let mut request = ioctl::Request::<ioctl::GetInterfaceNamePayload>::new();
        unsafe {
            ioctl::exec(
                fd.as_raw_fd(),
                libc::TUNGETIFF as libc::c_ulong,
                &mut request,
            )?
        };
        let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            name: request.name().into_owned(),
            fd,
        })
    }
}
