#[cfg(any(target_os = "macos", target_os = "ios"))]
mod tun_darwin;
#[cfg(any(target_os = "macos", target_os = "ios"))]
use tun_darwin as tun;

#[cfg(target_os = "linux")]
mod tun_linux;
#[cfg(target_os = "linux")]
use tun_linux as tun;

#[cfg(target_os = "windows")]
mod tun_windows;
#[cfg(target_os = "windows")]
use tun_windows as tun;

// TODO: Android and linux are nearly identical; use a common tunnel module?
#[cfg(target_os = "android")]
mod tun_android;
#[cfg(target_os = "android")]
use tun_android as tun;

#[cfg(target_family = "unix")]
mod utils;

use connlib_shared::{error::ConnlibError, messages::Interface, Callbacks, Error};
use connlib_shared::{Cidrv4, Cidrv6};
use ip_network::IpNetwork;
use ip_packet::{IpPacket, MutableIpPacket, Packet as _};
use std::collections::HashSet;
use std::io;
use std::net::IpAddr;
use std::task::{Context, Poll, Waker};
use tun::Tun;

pub struct Device {
    tun: Option<Tun>,
    waker: Option<Waker>,
}

#[allow(dead_code)]
fn ipv4(ip: IpNetwork) -> Option<Cidrv4> {
    match ip {
        IpNetwork::V4(v4) => Some(v4.into()),
        IpNetwork::V6(_) => None,
    }
}

#[allow(dead_code)]
fn ipv6(ip: IpNetwork) -> Option<Cidrv6> {
    match ip {
        IpNetwork::V4(_) => None,
        IpNetwork::V6(v6) => Some(v6.into()),
    }
}

impl Device {
    pub(crate) fn new() -> Self {
        Self {
            tun: None,
            waker: None,
        }
    }

    #[cfg(target_os = "android")]
    pub(crate) fn set_config(
        &mut self,
        config: &Interface,
        dns_config: Vec<IpAddr>,
        callbacks: &impl Callbacks,
    ) -> Result<(), ConnlibError> {
        self.tun = Some(Tun::new(config, dns_config, callbacks)?);

        if let Some(waker) = self.waker.take() {
            waker.wake();
        }

        Ok(())
    }

    #[cfg(any(
        target_os = "ios",
        target_os = "macos",
        target_os = "windows",
        target_os = "linux"
    ))]
    pub(crate) fn set_config(
        &mut self,
        config: &Interface,
        dns_config: Vec<IpAddr>,
        callbacks: &impl Callbacks,
    ) -> Result<(), ConnlibError> {
        // For macos the filedescriptor is the same throughout its lifetime.
        // If we reinitialize tun, we might drop the old tun after the new one is created
        // this unregisters the file descriptor with the reactor so we never wake up
        // in case an event is triggered.
        if self.tun.is_none() {
            self.tun = Some(Tun::new()?);
        }

        callbacks.on_set_interface_config(config.ipv4, config.ipv6, dns_config);

        if let Some(waker) = self.waker.take() {
            waker.wake();
        }

        Ok(())
    }

    #[cfg(target_family = "unix")]
    pub(crate) fn poll_read<'b>(
        &mut self,
        buf: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<MutableIpPacket<'b>>> {
        use ip_packet::Packet as _;

        let Some(tun) = self.tun.as_mut() else {
            self.waker = Some(cx.waker().clone());
            return Poll::Pending;
        };

        let n = std::task::ready!(tun.poll_read(&mut buf[20..], cx))?;

        if n == 0 {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "device is closed",
            )));
        }

        let packet = MutableIpPacket::new(&mut buf[..(n + 20)]).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "received bytes are not an IP packet",
            )
        })?;

        tracing::trace!(target: "wire::dev::recv", dst = %packet.destination(), src = %packet.source(), bytes = %packet.packet().len());

        Poll::Ready(Ok(packet))
    }

    #[cfg(target_family = "windows")]
    pub(crate) fn poll_read<'b>(
        &mut self,
        buf: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<MutableIpPacket<'b>>> {
        use ip_packet::Packet as _;

        let Some(tun) = self.tun.as_mut() else {
            self.waker = Some(cx.waker().clone());
            return Poll::Pending;
        };

        let n = std::task::ready!(tun.poll_read(&mut buf[20..], cx))?;

        if n == 0 {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "device is closed",
            )));
        }

        let packet = MutableIpPacket::new(&mut buf[..(n + 20)]).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "received bytes are not an IP packet",
            )
        })?;

        tracing::trace!(target: "wire::dev::recv", dst = %packet.destination(), src = %packet.source(), bytes = %packet.packet().len());

        Poll::Ready(Ok(packet))
    }

    pub(crate) fn name(&self) -> &str {
        self.tun
            .as_ref()
            .map(|t| t.name())
            .unwrap_or("uninitialized")
    }

    pub(crate) fn set_routes(
        &mut self,
        routes: HashSet<IpNetwork>,
        callbacks: &impl Callbacks,
    ) -> Result<(), Error> {
        self.tun_mut()?.set_routes(routes, callbacks)?;
        Ok(())
    }

    pub fn write(&self, packet: IpPacket<'_>) -> io::Result<usize> {
        tracing::trace!(target: "wire::dev::send", dst = %packet.destination(), src = %packet.source(), bytes = %packet.packet().len());

        match packet {
            IpPacket::Ipv4(msg) => self.tun()?.write4(msg.packet()),
            IpPacket::Ipv6(msg) => self.tun()?.write6(msg.packet()),
        }
    }

    fn tun(&self) -> io::Result<&Tun> {
        self.tun.as_ref().ok_or_else(io_error_not_initialized)
    }

    fn tun_mut(&mut self) -> io::Result<&mut Tun> {
        self.tun.as_mut().ok_or_else(io_error_not_initialized)
    }
}

fn io_error_not_initialized() -> io::Error {
    io::Error::new(io::ErrorKind::NotConnected, "device is not initialized yet")
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod ioctl {
    use super::*;
    use std::os::fd::RawFd;

    /// Executes the `ioctl` syscall on the given file descriptor with the provided request.
    ///
    /// # Safety
    ///
    /// The file descriptor must be open.
    pub(crate) unsafe fn exec<P>(
        fd: RawFd,
        code: libc::c_ulong,
        req: &mut Request<P>,
    ) -> io::Result<()> {
        let ret = unsafe { libc::ioctl(fd, code as _, req) };

        if ret < 0 {
            return Err(io::Error::last_os_error());
        }

        Ok(())
    }

    /// Represents a control request to an IO device, addresses by the device's name.
    ///
    /// The payload MUST also be `#[repr(C)]` and its layout depends on the particular request you are sending.
    #[repr(C)]
    pub(crate) struct Request<P> {
        pub(crate) name: [std::ffi::c_uchar; libc::IF_NAMESIZE],
        pub(crate) payload: P,
    }
}
