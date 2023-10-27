#![allow(clippy::module_inception)]

#[cfg(target_family = "unix")]
#[path = "device_channel/device_channel_unix.rs"]
mod device_channel;

#[cfg(target_family = "windows")]
#[path = "device_channel/device_channel_win.rs"]
mod device_channel;

pub(crate) use device_channel::*;
use std::borrow::Cow;

pub enum Packet<'a> {
    Ipv4(Cow<'a, [u8]>),
    Ipv6(Cow<'a, [u8]>),
}
