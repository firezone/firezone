use std::sync::Arc;

use libs_common::{Error, Result};
use tokio::io::unix::AsyncFd;

use crate::tun::{IfaceConfig, IfaceDevice};

#[derive(Debug)]
pub(crate) struct DeviceChannel(AsyncFd<Arc<IfaceDevice>>);

impl DeviceChannel {
    pub(crate) async fn mtu(&self) -> Result<usize> {
        self.0.get_ref().mtu().await
    }

    pub(crate) async fn read(&self, out: &mut [u8]) -> std::io::Result<usize> {
        loop {
            let mut guard = self.0.readable().await?;

            match guard.try_io(|inner| {
                inner.get_ref().read(out).map_err(|err| match err {
                    Error::IfaceRead(e) => e,
                    _ => panic!("Unexpected error while trying to read network interface"),
                })
            }) {
                Ok(result) => break result.map(|e| e.len()),
                Err(_would_block) => continue,
            }
        }
    }

    pub(crate) async fn write4(&self, buf: &[u8]) -> std::io::Result<usize> {
        loop {
            let mut guard = self.0.writable().await?;

            // write4 and write6 does the same
            match guard.try_io(|inner| match inner.get_ref().write4(buf) {
                0 => Err(std::io::Error::last_os_error()),
                i => Ok(i),
            }) {
                Ok(result) => break result,
                Err(_would_block) => continue,
            }
        }
    }

    pub(crate) async fn write6(&self, buf: &[u8]) -> std::io::Result<usize> {
        loop {
            let mut guard = self.0.writable().await?;

            // write4 and write6 does the same
            match guard.try_io(|inner| match inner.get_ref().write6(buf) {
                0 => Err(std::io::Error::last_os_error()),
                i => Ok(i),
            }) {
                Ok(result) => break result,
                Err(_would_block) => continue,
            }
        }
    }
}

pub(crate) async fn create_iface() -> Result<(IfaceConfig, DeviceChannel)> {
    let dev = Arc::new(IfaceDevice::new("utun").await?.set_non_blocking()?);
    let async_dev = Arc::clone(&dev);
    let device_channel = DeviceChannel(AsyncFd::new(async_dev)?);
    let iface_config = IfaceConfig(dev);

    Ok((iface_config, device_channel))
}
