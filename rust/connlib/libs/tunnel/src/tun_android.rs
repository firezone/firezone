use super::InterfaceConfig;
use ip_network::IpNetwork;
use libc::{close, open, O_RDWR};
use libs_common::{Callbacks, Error, Result, DNS_SENTINEL};
use std::{
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
    fn write(&self, _buf: &[u8]) -> usize {
        tracing::error!("`write` unimplemented on Android");
        0
    }

    pub async fn new(_name: &str) -> Result<Self> {
        // TODO: This won't actually work for non-root users...
        let fd = unsafe { open(b"/dev/net/tun\0".as_ptr() as _, O_RDWR) };
        // TODO: everything!
        if fd == -1 {
            Err(Error::Io(std::io::Error::last_os_error()))
        } else {
            Ok(Self { fd })
        }
    }

    pub fn set_non_blocking(self) -> Result<Self> {
        tracing::error!("`set_non_blocking` unimplemented on Android");
        Ok(self)
    }

    pub async fn mtu(&self) -> Result<usize> {
        tracing::error!("`mtu` unimplemented on Android");
        Ok(0)
    }

    pub fn write4(&self, src: &[u8]) -> usize {
        self.write(src)
    }

    pub fn write6(&self, src: &[u8]) -> usize {
        self.write(src)
    }

    pub fn read<'a>(&self, dst: &'a mut [u8]) -> Result<&'a mut [u8]> {
        tracing::error!("`read` unimplemented on Android");
        Ok(dst)
    }
}

impl IfaceConfig {
    #[tracing::instrument(level = "trace", skip(self, callbacks))]
    pub async fn set_iface_config(
        &mut self,
        config: &InterfaceConfig,
        callbacks: &impl Callbacks,
    ) -> Result<()> {
        callbacks.on_set_interface_config(config.ipv4, config.ipv6, DNS_SENTINEL);
        Ok(())
    }

    pub async fn add_route(&mut self, route: &IpNetwork, callbacks: &impl Callbacks) -> Result<()> {
        callbacks.on_add_route(serde_json::to_string(route)?);
        Ok(())
    }

    pub async fn up(&mut self) -> Result<()> {
        tracing::error!("`up` unimplemented on Android");
        Ok(())
    }
}
