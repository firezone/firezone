#![allow(clippy::module_inception)]

#[cfg(target_family = "unix")]
#[path = "device_channel/device_channel_unix.rs"]
mod device_channel;

#[cfg(target_family = "windows")]
#[path = "device_channel/device_channel_win.rs"]
mod device_channel;

use crate::{Device, MAX_UDP_SIZE};
use connlib_shared::{messages::Interface, CallbackErrorFacade, Callbacks, Result};
use ip_network::IpNetwork;
use std::sync::{
    atomic::{AtomicUsize, Ordering::Relaxed},
    Arc,
};
use tun::IfaceDevice;

mod tun;

pub(crate) use device_channel::DeviceIo;

pub(crate) struct IfaceConfig {
    mtu: AtomicUsize,
    iface: IfaceDevice,
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
        let io = DeviceIo::new(stream);
        let mtu = iface.mtu().await?;
        let config = Arc::new(IfaceConfig {
            iface,
            mtu: AtomicUsize::new(mtu),
        });
        Ok(Some(Device {
            io,
            config,
            buf: Box::new([0u8; MAX_UDP_SIZE]),
        }))
    }
}

pub(crate) async fn create_iface(
    config: &Interface,
    callbacks: &CallbackErrorFacade<impl Callbacks>,
) -> Result<Device> {
    let (iface, stream) = IfaceDevice::new(config, callbacks).await?;
    iface.up().await?;
    let io = DeviceIo::new(stream);
    let mtu = iface.mtu().await?;
    let config = Arc::new(IfaceConfig {
        iface,
        mtu: AtomicUsize::new(mtu),
    });

    Ok(Device {
        io,
        config,
        buf: Box::new([0u8; MAX_UDP_SIZE]),
    })
}
