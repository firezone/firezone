use std::sync::{
    atomic::{AtomicUsize, Ordering::Relaxed},
    Arc,
};

use connlib_shared::{messages::Interface, CallbackErrorFacade, Callbacks, Result};
use ip_network::IpNetwork;
use pnet_packet::Packet;
use tokio::io::{unix::AsyncFd, Interest};

use tun::{IfaceDevice, IfaceStream};

use crate::ip_packet::IpPacket;
use crate::{Device, MAX_UDP_SIZE};

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
    pub fn write(&self, packet: IpPacket<'_>) -> std::io::Result<usize> {
        match packet {
            IpPacket::Ipv4Packet(msg) => self.0.get_ref().write4(msg.packet()),
            IpPacket::Ipv6Packet(msg) => self.0.get_ref().write6(msg.packet()),
        }
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
    let io = DeviceIo(stream);
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
