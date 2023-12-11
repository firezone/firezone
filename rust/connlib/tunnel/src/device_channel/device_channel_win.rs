use crate::device_channel::Packet;
use crate::Device;
use connlib_shared::{messages::Interface, Callbacks, Result};
use ip_network::IpNetwork;
use std::task::{Context, Poll};

pub(crate) struct DeviceIo;

impl DeviceIo {
    pub fn poll_read(&self, _: &mut [u8], _: &mut Context<'_>) -> Poll<std::io::Result<usize>> {
        todo!()
    }

    pub fn write(&self, _: Packet<'_>) -> std::io::Result<usize> {
        todo!()
    }
}

pub(super) async fn create_iface(_: &Interface, _: &impl Callbacks) -> Result<Device> {
    todo!()
}
