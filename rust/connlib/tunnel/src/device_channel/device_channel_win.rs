use connlib_shared::{messages::Interface, CallbackErrorFacade, Callbacks, Result};
use ip_network::IpNetwork;
use std::sync::{
    atomic::{AtomicUsize, Ordering::Relaxed},
    Arc,
};
use tun::IfaceDevice;
mod tun;

#[derive(Clone)]
pub(crate) struct DeviceIo(Arc<IfaceDevice>);

pub(crate) struct IfaceConfig {
    mtu: AtomicUsize,
    iface: Arc<IfaceDevice>,
}

impl DeviceIo {
    pub async fn read(&self, out: &mut [u8]) -> std::io::Result<usize> {
        Ok(self.0.read(out).await.unwrap().len())
    }

    pub fn write4(&self, buf: &[u8]) -> std::io::Result<usize> {
        Ok(self.0.write4(buf))
    }

    pub fn write6(&self, buf: &[u8]) -> std::io::Result<usize> {
        Ok(self.0.write6(buf))
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
    ) -> Result<()> {
        self.iface.add_route(route, callbacks).await
    }
}

pub(crate) async fn create_iface(
    config: &Interface,
    callbacks: &CallbackErrorFacade<impl Callbacks>,
) -> Result<(IfaceConfig, DeviceIo)> {
    let iface = Arc::new(IfaceDevice::new(config, callbacks).await?);
    iface.up().await?;
    let device_io = DeviceIo(iface.clone());
    let mtu = iface.mtu().await?;
    let iface_config = IfaceConfig {
        iface,
        mtu: AtomicUsize::new(mtu),
    };

    Ok((iface_config, device_io))
}