use connlib_shared::{messages::Interface, CallbackErrorFacade, Callbacks, Result};
use ip_network::IpNetwork;

#[derive(Clone)]
pub(crate) struct DeviceIo;

pub(crate) struct IfaceConfig;

impl DeviceIo {
    pub async fn read(&self, _: &mut [u8]) -> std::io::Result<usize> {
        todo!()
    }

    pub fn write4(&self, _: &[u8]) -> std::io::Result<usize> {
        todo!()
    }

    pub fn write6(&self, _: &[u8]) -> std::io::Result<usize> {
        todo!()
    }
}

impl IfaceConfig {
    pub(crate) fn mtu(&self) -> usize {
        todo!()
    }

    pub(crate) async fn refresh_mtu(&self) -> Result<usize> {
        todo!()
    }

    pub(crate) async fn add_route(
        &self,
        _: IpNetwork,
        _: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<()> {
        todo!()
    }
}

pub(crate) async fn create_iface(
    _: &Interface,
    _: &CallbackErrorFacade<impl Callbacks>,
) -> Result<(IfaceConfig, DeviceIo)> {
    todo!()
}
