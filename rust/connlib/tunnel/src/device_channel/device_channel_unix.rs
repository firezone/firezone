use std::sync::{
    atomic::{AtomicUsize, Ordering::Relaxed},
    Arc,
};

use connlib_shared::{messages::Interface, CallbackErrorFacade, Callbacks, Result};
use ip_network::IpNetwork;
use tokio::io::{unix::AsyncFd, Interest};

use tun::{IfaceDevice, IfaceStream};

use crate::Device;

mod tun;

pub(crate) struct IfaceConfig {
    mtu: AtomicUsize,
    iface: IfaceDevice,
}

#[derive(Clone)]
pub(crate) struct DeviceIo(Arc<AsyncFd<IfaceStream>>);

impl DeviceIo {
    pub async fn read(&self, out: &mut [u8]) -> std::io::Result<usize> {
        self.0
            .async_io(Interest::READABLE, |inner| inner.read(out))
            .await
    }

    // Note: write is synchronous because it's non-blocking
    // and some losiness is acceptable and increseases performance
    // since we don't block the reading loops.
    pub fn write4(&self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.get_ref().write4(buf)
    }

    pub fn write6(&self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.get_ref().write6(buf)
    }
}

impl IfaceConfig {
    pub(crate) fn mtu(&self) -> usize {
        self.mtu.load(Relaxed)
    }

    pub(crate) async fn refresh_mtu(&self) -> Result<usize> {
        let mtu = self.iface.mtu().await?;
        self.mtu.store(mtu, Relaxed);
        Ok(mtu)
    }

    pub(crate) async fn add_route(
        &self,
        route: IpNetwork,
        callbacks: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<Option<Device>> {
        let Some((iface, stream)) = self.iface.add_route(route, callbacks).await? else {
            return Ok(None);
        };
        let io = DeviceIo(stream);
        let mtu = iface.mtu().await?;
        let config = Arc::new(IfaceConfig {
            iface,
            mtu: AtomicUsize::new(mtu),
        });
        Ok(Some(Device { io, config }))
    }
}

pub(crate) async fn create_iface(
    config: &Interface,
    callbacks: &CallbackErrorFacade<impl Callbacks>,
) -> Result<Device> {
    let (iface, stream) = IfaceDevice::new(config, callbacks).await?;
    iface.up().await?;
    let io = DeviceIo(stream);
    let mtu = iface.mtu().await?;
    let config = Arc::new(IfaceConfig {
        iface,
        mtu: AtomicUsize::new(mtu),
    });

    Ok(Device { config, io })
}
