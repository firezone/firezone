#![allow(clippy::module_inception)]

#[cfg(target_family = "unix")]
#[path = "device_channel/device_channel_unix.rs"]
mod device_channel;

#[cfg(target_family = "windows")]
#[path = "device_channel/device_channel_win.rs"]
mod device_channel;

use crate::device_channel::device_channel::tun::IfaceDevice;
use crate::ip_packet::MutableIpPacket;
use crate::DnsFallbackStrategy;
use connlib_shared::error::ConnlibError;
use connlib_shared::messages::Interface;
use connlib_shared::{Callbacks, Error};
use ip_network::IpNetwork;
use std::borrow::Cow;
use std::io;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::task::{ready, Context, Poll};

pub(crate) use device_channel::*;

pub struct Device {
    mtu: AtomicUsize,
    iface: IfaceDevice,
    io: DeviceIo,
}

impl Device {
    #[cfg(target_family = "unix")]
    pub(crate) async fn new(
        config: &Interface,
        callbacks: &impl Callbacks<Error = Error>,
        dns: DnsFallbackStrategy,
    ) -> Result<Device, ConnlibError> {
        let (iface, stream) = IfaceDevice::new(config, callbacks, dns).await?;
        iface.up().await?;
        let io = DeviceIo(stream);
        let mtu = AtomicUsize::new(ioctl::interface_mtu_by_name(iface.name())?);

        Ok(Device { io, mtu, iface })
    }

    #[cfg(target_family = "windows")]
    pub(crate) async fn new(
        config: &Interface,
        callbacks: &impl Callbacks<Error = Error>,
        fallback_strategy: DnsFallbackStrategy,
    ) -> Result<Device, ConnlibError> {
        todo!()
    }

    pub(crate) fn poll_read<'b>(
        &self,
        buf: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<Option<MutableIpPacket<'b>>>> {
        let res = ready!(self.io.poll_read(&mut buf[..self.mtu()], cx))?;

        if res == 0 {
            return Poll::Ready(Ok(None));
        }

        Poll::Ready(Ok(Some(MutableIpPacket::new(&mut buf[..res]).ok_or_else(
            || {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "received bytes are not an IP packet",
                )
            },
        )?)))
    }

    pub(crate) fn mtu(&self) -> usize {
        self.mtu.load(Ordering::Relaxed)
    }

    #[cfg(target_family = "unix")]
    pub(crate) async fn add_route(
        &self,
        route: IpNetwork,
        callbacks: &impl Callbacks<Error = Error>,
    ) -> Result<Option<Device>, Error> {
        let Some((iface, stream)) = self.iface.add_route(route, callbacks).await? else {
            return Ok(None);
        };
        let io = DeviceIo(stream);
        let mtu = AtomicUsize::new(ioctl::interface_mtu_by_name(iface.name())?);

        Ok(Some(Device { io, mtu, iface }))
    }

    #[cfg(target_family = "windows")]
    pub(crate) async fn add_route(
        &self,
        route: IpNetwork,
        callbacks: &impl Callbacks<Error = Error>,
    ) -> Result<Option<Device>, Error> {
        todo!()
    }

    #[cfg(target_family = "unix")]
    pub(crate) fn refresh_mtu(&self) -> Result<usize, Error> {
        let mtu = ioctl::interface_mtu_by_name(self.iface.name())?;
        self.mtu.store(mtu, Ordering::Relaxed);

        Ok(mtu)
    }

    #[cfg(target_family = "windows")]
    pub(crate) fn refresh_mtu(&self) -> Result<usize, Error> {
        todo!()
    }

    pub fn write(&self, packet: Packet<'_>) -> io::Result<usize> {
        self.io.write(packet)
    }
}

pub enum Packet<'a> {
    Ipv4(Cow<'a, [u8]>),
    Ipv6(Cow<'a, [u8]>),
}
