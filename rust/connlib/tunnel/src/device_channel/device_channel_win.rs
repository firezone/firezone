use crate::device_channel::Packet;
use crate::Device;
use crate::DnsFallbackStrategy;
use connlib_shared::{messages::Interface, Callbacks, Result};
use ip_network::IpNetwork;
use std::task::{Context, Poll};

// TODO: Fill all this out. These are just stubs to test the GUI.

pub(crate) struct DeviceIo;

impl DeviceIo {
    pub fn poll_read(&self, _: &mut [u8], _: &mut Context<'_>) -> Poll<std::io::Result<usize>> {
        // Incoming packets will never appear
        Poll::Pending
    }

    pub fn write(&self, packet: Packet<'_>) -> std::io::Result<usize> {
        // All outgoing packets are successfully written to the void
        match packet {
            Packet::Ipv4(msg) => Ok(msg.len()),
            Packet::Ipv6(msg) => Ok(msg.len()),
        }
    }
}

pub(super) async fn create_iface(
    _: &Interface,
    _: &impl Callbacks,
    _: DnsFallbackStrategy,
) -> Result<Device> {
    todo!()
}
