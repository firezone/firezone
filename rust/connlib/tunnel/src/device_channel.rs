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

use crate::ip_packet::{IpPacket, MutableIpPacket};
use connlib_shared::error::ConnlibError;
use connlib_shared::messages::Interface;
use connlib_shared::{Callbacks, Error};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use pnet_packet::Packet;
use std::collections::HashSet;
use std::io;
use std::net::IpAddr;
use std::task::{Context, Poll, Waker};
use std::time::{Duration, Instant};
use tun::Tun;

pub struct Device {
    mtu: usize,
    tun: Option<Tun>,
    waker: Option<Waker>,
    mtu_refreshed_at: Instant,
}

#[allow(dead_code)]
fn ipv4(ip: &IpNetwork) -> Option<&Ipv4Network> {
    match ip {
        IpNetwork::V4(v4) => Some(v4),
        IpNetwork::V6(_) => None,
    }
}

#[allow(dead_code)]
fn ipv6(ip: &IpNetwork) -> Option<&Ipv6Network> {
    match ip {
        IpNetwork::V4(_) => None,
        IpNetwork::V6(v6) => Some(v6),
    }
}

impl Device {
    pub(crate) fn new() -> Self {
        Self {
            tun: None,
            mtu: 1_280,
            waker: None,
            mtu_refreshed_at: Instant::now(),
        }
    }

    #[cfg(target_family = "unix")]
    pub(crate) fn initialize(
        &mut self,
        config: &Interface,
        dns_config: Vec<IpAddr>,
        callbacks: &impl Callbacks<Error = Error>,
    ) -> Result<(), ConnlibError> {
        let tun = Tun::new(config, dns_config, callbacks)?;
        let mtu = ioctl::interface_mtu_by_name(tun.name())?;

        self.tun = Some(tun);
        self.mtu = mtu;

        if let Some(waker) = self.waker.take() {
            waker.wake();
        }

        Ok(())
    }

    #[cfg(target_family = "windows")]
    pub(crate) fn initialize(
        &mut self,
        config: &Interface,
        dns_config: Vec<IpAddr>,
        _: &impl Callbacks<Error = Error>,
    ) -> Result<(), ConnlibError> {
        let tun = Tun::new(config, dns_config)?;

        self.tun = Some(tun);

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
        let Some(tun) = self.tun.as_mut() else {
            self.waker = Some(cx.waker().clone());
            return Poll::Pending;
        };

        use pnet_packet::Packet as _;

        if self.mtu_refreshed_at.elapsed() > Duration::from_secs(30) {
            let mtu = ioctl::interface_mtu_by_name(tun.name())?;
            self.mtu = mtu;
            self.mtu_refreshed_at = Instant::now();
        }

        let n = std::task::ready!(tun.poll_read(&mut buf[..self.mtu], cx))?;

        if n == 0 {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "device is closed",
            )));
        }

        let packet = MutableIpPacket::new(&mut buf[..n]).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "received bytes are not an IP packet",
            )
        })?;

        tracing::trace!(target: "wire", from = "device", dest = %packet.destination(), bytes = %packet.packet().len());

        Poll::Ready(Ok(packet))
    }

    #[cfg(target_family = "windows")]
    pub(crate) fn poll_read<'b>(
        &mut self,
        buf: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<MutableIpPacket<'b>>> {
        let Some(tun) = self.tun.as_mut() else {
            self.waker = Some(cx.waker().clone());
            return Poll::Pending;
        };

        use pnet_packet::Packet as _;

        if self.mtu_refreshed_at.elapsed() > Duration::from_secs(30) {
            // TODO
        }

        let n = std::task::ready!(tun.poll_read(&mut buf[..self.mtu], cx))?;

        if n == 0 {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "device is closed",
            )));
        }

        let packet = MutableIpPacket::new(&mut buf[..n]).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "received bytes are not an IP packet",
            )
        })?;

        tracing::trace!(target: "wire", from = "device", dest = %packet.destination(), bytes = %packet.packet().len());

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
        _callbacks: &impl Callbacks<Error = Error>,
    ) -> Result<(), Error> {
        self.tun_mut()?.set_routes(routes, _callbacks)?;
        Ok(())
    }

    pub fn write(&self, packet: IpPacket<'_>) -> io::Result<usize> {
        tracing::trace!(target: "wire", to = "device", bytes = %packet.packet().len());

        match packet {
            IpPacket::Ipv4Packet(msg) => self.tun()?.write4(msg.packet()),
            IpPacket::Ipv6Packet(msg) => self.tun()?.write6(msg.packet()),
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

#[cfg(target_family = "unix")]
mod ioctl {
    use super::*;
    use std::os::fd::RawFd;
    use tun::SIOCGIFMTU;

    pub(crate) fn interface_mtu_by_name(name: &str) -> io::Result<usize> {
        let socket = Socket::ip4()?;
        let mut request = Request::<GetInterfaceMtuPayload>::new(name)?;

        // Safety: The file descriptor is open.
        unsafe {
            exec(socket.fd, SIOCGIFMTU, &mut request)?;
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
