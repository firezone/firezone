#![allow(clippy::module_inception)]
#![cfg_attr(target_family = "windows", allow(dead_code))] // TODO: Remove when windows is fully implemented.

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

use crate::ip_packet::{IpPacket, MutableIpPacket};
use connlib_shared::{error::ConnlibError, messages::Interface, Callbacks, Error};
use connlib_shared::{Cidrv4, Cidrv6};
use ip_network::IpNetwork;
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
            mtu: 1_280,
            waker: None,
            mtu_refreshed_at: Instant::now(),
        }
    }

    #[cfg(any(target_os = "android", target_os = "linux"))]
    pub(crate) fn set_config(
        &mut self,
        config: &Interface,
        dns_config: Vec<IpAddr>,
        callbacks: &impl Callbacks,
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

    #[cfg(any(target_os = "ios", target_os = "macos"))]
    pub(crate) fn set_config(
        &mut self,
        config: &Interface,
        dns_config: Vec<IpAddr>,
        callbacks: &impl Callbacks,
    ) -> Result<(), ConnlibError> {
        // For macos the filedescriptor is the same throughout its lifetime.
        // If we reinitialzie tun, we might drop the old tun after the new one is created
        // this unregisters the file descriptor with the reactor so we never wake up
        // in case an event is triggered.
        if self.tun.is_none() {
            self.tun = Some(Tun::new()?);
        }

        self.mtu = ioctl::interface_mtu_by_name(self.tun.as_ref().unwrap().name())?;

        callbacks.on_set_interface_config(config.ipv4, config.ipv6, dns_config);

        if let Some(waker) = self.waker.take() {
            waker.wake();
        }

        Ok(())
    }

    #[cfg(target_family = "windows")]
    pub(crate) fn set_config(
        &mut self,
        config: &Interface,
        dns_config: Vec<IpAddr>,
        _: &impl Callbacks,
    ) -> Result<(), ConnlibError> {
        if self.tun.is_none() {
            self.tun = Some(Tun::new()?);
        }

        self.tun.as_ref().unwrap().set_config(config, &dns_config)?;

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

        tracing::trace!(target: "wire", from = "device", dst = %packet.destination(), src = %packet.source(), bytes = %packet.packet().len());

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

        tracing::trace!(target: "wire", from = "device", dst = %packet.destination(), src = %packet.source(), bytes = %packet.packet().len());

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
        tracing::trace!(target: "wire", to = "device", dst = %packet.destination(), src = %packet.source(), bytes = %packet.packet().len());

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

#[cfg(test)]
mod tests {
    #[derive(Clone, Default)]
    struct Callbacks {}

    impl connlib_shared::Callbacks for Callbacks {}

    // I assume this is not practical to run on macOS because of the tight restrictions on NetworkExtensions
    // It requires sudo on Linux and elevation on Windows, since it creates the tunnel interface
    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn device_linux() {
        device_common();
    }

    #[cfg(target_os = "windows")]
    #[tokio::test]
    async fn device_windows() {
        // Install wintun so the test can run
        // CI only needs x86_64 for now
        let wintun_bytes = include_bytes!("../../../gui-client/wintun/bin/amd64/wintun.dll");
        let wintun_path = connlib_shared::windows::wintun_dll_path().unwrap();
        tokio::fs::create_dir_all(wintun_path.parent().unwrap())
            .await
            .unwrap();
        tokio::fs::write(&wintun_path, wintun_bytes).await.unwrap();

        device_common();
    }

    fn device_common() {
        let mut dev = super::Device::new();

        let config = connlib_shared::messages::Interface {
            ipv4: [100, 71, 96, 96].into(),
            ipv6: [0xfd00, 0x2021, 0x1111, 0x0, 0x0, 0x0, 0x0019, 0x6538].into(),
            upstream_dns: vec![connlib_shared::messages::DnsServer::IpPort(
                connlib_shared::messages::IpDnsServer {
                    address: ([1, 1, 1, 1], 53).into(),
                },
            )],
        };
        let dns_config = vec![[100, 100, 111, 1].into()];
        let callbacks = Callbacks::default();
        dev.initialize(&config, dns_config, &callbacks).unwrap();
    }
}
