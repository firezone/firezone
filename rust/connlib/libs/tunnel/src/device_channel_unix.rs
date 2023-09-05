use std::sync::{
    atomic::{AtomicUsize, Ordering::Relaxed},
    Arc,
};

use libs_common::{messages::Interface, CallbackErrorFacade, Callbacks, Error, Result};
use tokio::io::unix::AsyncFd;

use crate::tun::{IfaceConfig, IfaceDevice};

#[derive(Debug)]
pub(crate) struct DeviceChannel {
    device: AsyncFd<Arc<IfaceDevice>>,
    mtu: AtomicUsize,
}

impl DeviceChannel {
    pub(crate) fn mtu(&self) -> usize {
        self.mtu.load(Relaxed)
    }

    pub(crate) async fn refresh_mtu(&self) -> Result<usize> {
        let mtu = self.device.get_ref().mtu().await?;
        self.mtu.store(mtu, Relaxed);
        Ok(mtu)
    }

    #[tracing::instrument(level = "trace", skip(self, out))]
    pub(crate) async fn read(&self, out: &mut [u8]) -> std::io::Result<usize> {
        loop {
            let mut guard = self.device.readable().await?;

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
            let mut guard = self.device.writable().await?;

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
            let mut guard = self.device.writable().await?;

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

pub(crate) async fn create_iface(
    config: &Interface,
    callbacks: &CallbackErrorFacade<impl Callbacks>,
) -> Result<(IfaceConfig, DeviceChannel)> {
    let dev = Arc::new(IfaceDevice::new(config, callbacks).await?);
    let async_dev = Arc::clone(&dev);
    let mtu = async_dev.mtu().await?;
    let device_channel = DeviceChannel {
        device: AsyncFd::new(async_dev)?,
        mtu: AtomicUsize::new(mtu),
    };
    let mut iface_config = IfaceConfig(dev);
    iface_config.up().await?;

    Ok((iface_config, device_channel))
}
