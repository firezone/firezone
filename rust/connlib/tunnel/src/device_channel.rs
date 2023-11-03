#![allow(clippy::module_inception)]

#[cfg(target_family = "unix")]
#[path = "device_channel/device_channel_unix.rs"]
mod device_channel;

#[cfg(target_family = "windows")]
#[path = "device_channel/device_channel_win.rs"]
mod device_channel;

use crate::ip_packet::MutableIpPacket;
pub(crate) use device_channel::*;
use std::borrow::Cow;
use std::io;
use std::sync::Arc;
use std::task::{ready, Context, Poll};

#[derive(Clone)]
pub struct Device {
    pub(crate) config: Arc<IfaceConfig>, // TODO: Make private
    io: DeviceIo,
}

impl Device {
    pub(crate) fn poll_read<'b>(
        &mut self,
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

    pub fn write(&self, packet: Packet<'_>) -> io::Result<usize> {
        self.io.write(packet)
    }
}

pub enum Packet<'a> {
    Ipv4(Cow<'a, [u8]>),
    Ipv6(Cow<'a, [u8]>),
}
