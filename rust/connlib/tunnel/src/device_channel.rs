#![allow(clippy::module_inception)]
#![cfg_attr(target_family = "windows", allow(dead_code))] // TODO: Remove when windows is fully implemented.

#[cfg(any(target_os = "macos", target_os = "ios"))]
#[path = "device_channel/tun_darwin.rs"]
mod tun;

#[cfg(target_os = "linux")]
#[path = "device_channel/tun_linux.rs"]
mod tun;

#[cfg(target_family = "windows")]
#[path = "device_channel/tun_windows.rs"]
mod tun;

// TODO: Android and linux are nearly identical; use a common tunnel module?
#[cfg(target_os = "android")]
#[path = "device_channel/tun_android.rs"]
mod tun;

use crate::DnsFallbackStrategy;
use connlib_shared::error::ConnlibError;
use connlib_shared::messages::Interface;
use connlib_shared::{Callbacks, Error};
use ip_network::IpNetwork;
use std::borrow::Cow;
use std::io;
use std::task::{Context, Poll};
use std::time::Duration;
use tun::Tun;

pub struct Device {
    mtu: usize,
    tun: Tun,

    mtu_refresh_interval: tokio::time::Interval,
}

impl Device {
    #[cfg(target_family = "unix")]
    pub(crate) fn new(
        config: &Interface,
        callbacks: &impl Callbacks<Error = Error>,
        dns: DnsFallbackStrategy,
    ) -> Result<Device, ConnlibError> {
        let tun = Tun::new(config, callbacks, dns)?;
        let mtu = ioctl::interface_mtu_by_name(tun.name())?;

        Ok(Device {
            mtu,
            tun,
            mtu_refresh_interval: tokio::time::interval(Duration::from_secs(30)),
        })
    }

    #[cfg(target_family = "windows")]
    pub(crate) fn new(
        _: &Interface,
        _: &impl Callbacks<Error = Error>,
        _: DnsFallbackStrategy,
    ) -> Result<Device, ConnlibError> {
        Ok(Device {
            tun: Tun::new(),
            mtu: 0, // Dummy value for now.
            mtu_refresh_interval: tokio::time::interval(Duration::from_secs(30)),
        })
    }

    #[cfg(target_family = "unix")]
    pub(crate) fn poll_read<'b>(
        &mut self,
        buf: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<Option<&'b mut [u8]>>> {
        if self.mtu_refresh_interval.poll_tick(cx).is_ready() {
            let mtu = ioctl::interface_mtu_by_name(self.tun.name())
                .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
            self.mtu = mtu;
        }

        let n = std::task::ready!(self.tun.poll_read(&mut buf[..self.mtu], cx))?;

        if n == 0 {
            return Poll::Ready(Ok(None));
        }

        Poll::Ready(Ok(Some(&mut buf[..n])))
    }

    #[cfg(target_family = "windows")]
    pub(crate) fn poll_read<'b>(
        &mut self,
        _: &'b mut [u8],
        _: &mut Context<'_>,
    ) -> Poll<io::Result<Option<&'b mut [u8]>>> {
        Poll::Pending
    }

    #[cfg(target_family = "unix")]
    pub(crate) fn add_route(
        &self,
        route: IpNetwork,
        callbacks: &impl Callbacks<Error = Error>,
    ) -> Result<Option<Device>, Error> {
        let Some(tun) = self.tun.add_route(route, callbacks)? else {
            return Ok(None);
        };
        let mtu = ioctl::interface_mtu_by_name(tun.name())?;

        Ok(Some(Device {
            mtu,
            tun,
            mtu_refresh_interval: tokio::time::interval(Duration::from_secs(30)),
        }))
    }

    #[cfg(target_family = "windows")]
    pub(crate) fn add_route(
        &self,
        _: IpNetwork,
        _: &impl Callbacks<Error = Error>,
    ) -> Result<Option<Device>, Error> {
        Ok(None)
    }

    pub fn write(&self, packet: Packet<'_>) -> io::Result<usize> {
        match packet {
            Packet::Ipv4(msg) => self.tun.write4(&msg),
            Packet::Ipv6(msg) => self.tun.write6(&msg),
        }
    }
}

pub enum Packet<'a> {
    Ipv4(Cow<'a, [u8]>),
    Ipv6(Cow<'a, [u8]>),
}

#[cfg(target_family = "unix")]
mod ioctl {
    use super::*;
    use std::os::fd::RawFd;
    use tun::SIOCGIFMTU;

    pub(crate) fn interface_mtu_by_name(name: &str) -> Result<usize, ConnlibError> {
        let socket = Socket::ip4()?;
        let request = Request::<GetInterfaceMtuPayload>::new(name)?;

        // Safety: The file descriptor is open.
        unsafe {
            exec(socket.fd, SIOCGIFMTU, &request)?;
        }

        Ok(request.payload.mtu as usize)
    }

    /// Executes the `ioctl` syscall on the given file descriptor with the provided request.
    ///
    /// # Safety
    ///
    /// The file descriptor must be open.
    pub(crate) unsafe fn exec<P>(
        fd: RawFd,
        code: libc::c_ulong,
        req: &Request<P>,
    ) -> Result<(), ConnlibError> {
        let ret = unsafe { libc::ioctl(fd, code as _, req) };

        if ret < 0 {
            return Err(io::Error::last_os_error().into());
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

    /// A socket newtype which closes the file descriptor on drop.
    struct Socket {
        fd: RawFd,
    }

    impl Socket {
        fn ip4() -> io::Result<Socket> {
            // Safety: All provided parameters are constants.
            let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_STREAM, libc::IPPROTO_IP) };

            if fd == -1 {
                return Err(io::Error::last_os_error());
            }

            Ok(Self { fd })
        }
    }

    impl Drop for Socket {
        fn drop(&mut self) {
            // Safety: This is the only call to `close` and it happens when `Guard` is being dropped.
            unsafe { libc::close(self.fd) };
        }
    }

    impl Request<GetInterfaceMtuPayload> {
        fn new(name: &str) -> io::Result<Self> {
            if name.len() > libc::IF_NAMESIZE {
                return Err(io::ErrorKind::InvalidInput.into());
            }

            let mut request = Request {
                name: [0u8; libc::IF_NAMESIZE],
                payload: Default::default(),
            };

            request.name[..name.len()].copy_from_slice(name.as_bytes());

            Ok(request)
        }
    }

    #[derive(Default)]
    #[repr(C)]
    struct GetInterfaceMtuPayload {
        mtu: libc::c_int,
    }
}
