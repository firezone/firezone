use super::InterfaceConfig;
use ip_network::IpNetwork;
use libc::{close, read, write};
use libs_common::{CallbackErrorFacade, Callbacks, Error, Result, DNS_SENTINEL};
use std::{
    io,
    os::fd::{AsRawFd, RawFd},
    sync::Arc,
};

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

    pub async unsafe fn new(fd: Option<i32>) -> Result<Self> {
        log::debug!("tunnel allocation unimplemented on Android; using provided fd");
        Ok(Self {
            fd: fd.expect("file descriptor must be provided!") as RawFd,
        })
    }

    pub fn set_non_blocking(self) -> Result<Self> {
        // Anrdoid already opens the tun device in non-blocking mode for us
        log::debug!("`set_non_blocking` unimplemented on Android");
        Ok(self)
    }

    pub async fn mtu(&self) -> Result<usize> {
        // We stick with a hardcoded MTU of 1280 for now. This could be improved by
        // finding the MTU of the underlying physical interface and subtracting 80
        // from it for the WireGuard overhead, but that's a lot of complexity
        // for little gain.
        log::debug!("`mtu` unimplemented on Android; using 1280");
        Ok(1280)
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

impl IfaceConfig {
    pub async fn set_iface_config(
        &mut self,
        config: &InterfaceConfig,
        callbacks: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<()> {
        callbacks.on_set_interface_config(config.ipv4, config.ipv6, DNS_SENTINEL)
    }

    pub async fn add_route(
        &mut self,
        route: IpNetwork,
        callbacks: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<()> {
        callbacks.on_add_route(route)
    }

    pub async fn up(&mut self) -> Result<()> {
        log::debug!("`up` unimplemented on Android");
        Ok(())
    }
}
