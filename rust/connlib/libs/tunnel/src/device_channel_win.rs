use crate::tun::IfaceConfig;
use libs_common::Result;

#[derive(Debug)]
pub(crate) struct DeviceChannel;

impl DeviceChannel {
    pub(crate) async fn mtu(&self) -> Result<usize> {
        todo!()
    }

    pub(crate) async fn read(&self, _out: &mut [u8]) -> std::io::Result<usize> {
        todo!()
    }

    pub(crate) async fn write4(&self, _buf: &[u8]) -> std::io::Result<usize> {
        todo!()
    }

    pub(crate) async fn write6(&self, _buf: &[u8]) -> std::io::Result<usize> {
        todo!()
    }
}

pub(crate) async fn create_iface() -> Result<(IfaceConfig, DeviceChannel)> {
    todo!()
}
