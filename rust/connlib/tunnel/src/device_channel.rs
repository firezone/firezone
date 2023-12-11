#![allow(clippy::module_inception)]

#[cfg(target_family = "unix")]
#[path = "device_channel/device_channel_unix.rs"]
mod device_channel;

#[cfg(target_family = "windows")]
#[path = "device_channel/device_channel_win.rs"]
mod device_channel;

use crate::ip_packet::MutableIpPacket;
use crate::DnsFallbackStrategy;
use connlib_shared::error::ConnlibError;
use connlib_shared::messages::Interface;
use connlib_shared::{Callbacks, Error};
use ip_network::IpNetwork;
use std::borrow::Cow;
use std::io;
use std::task::{ready, Context, Poll};

pub(crate) use device_channel::*;

pub struct Device {
    config: IfaceConfig,
    io: DeviceIo,
}

impl Device {
    pub(crate) async fn new(
        config: &Interface,
        callbacks: &impl Callbacks<Error = Error>,
        fallback_strategy: DnsFallbackStrategy,
    ) -> Result<Device, ConnlibError> {
        create_iface(config, callbacks, fallback_strategy).await
    }

    pub(crate) fn poll_read<'b>(
        &self,
        buf: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<Option<MutableIpPacket<'b>>>> {
        let res = ready!(self.io.poll_read(&mut buf[..self.config.mtu()], cx))?;

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

    pub(crate) async fn add_route(
        &self,
        route: IpNetwork,
        callbacks: &impl Callbacks<Error = Error>,
    ) -> Result<Option<Device>, Error> {
        self.config.add_route(route, callbacks).await
    }

    pub(crate) fn refresh_mtu(&self) -> Result<usize, Error> {
        self.config.refresh_mtu()
    }

    pub fn write(&self, packet: Packet<'_>) -> io::Result<usize> {
        self.io.write(packet)
    }
}

pub enum Packet<'a> {
    Ipv4(Cow<'a, [u8]>),
    Ipv6(Cow<'a, [u8]>),
}
