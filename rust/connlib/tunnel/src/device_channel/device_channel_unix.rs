use std::io;
use std::os::fd::RawFd;
use std::sync::{atomic::AtomicUsize, Arc};
use std::task::{ready, Context, Poll};

use tokio::io::{unix::AsyncFd, Ready};

use connlib_shared::{messages::Interface, Callbacks, Error, Result};
use tun::{IfaceDevice, IfaceStream, SIOCGIFMTU};

use crate::device_channel::{Device, Packet};
use crate::DnsFallbackStrategy;

pub(super) mod tun;

pub(crate) struct DeviceIo(pub(crate) Arc<AsyncFd<IfaceStream>>);

impl DeviceIo {
    pub fn poll_read(&self, out: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        loop {
            let mut guard = ready!(self.0.poll_read_ready(cx))?;

            match guard.get_inner().read(out) {
                Ok(n) => return Poll::Ready(Ok(n)),
                Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                    // a read has blocked, but a write might still succeed.
                    // clear only the read readiness.
                    guard.clear_ready_matching(Ready::READABLE);
                    continue;
                }
                Err(e) => return Poll::Ready(Err(e)),
            }
        }
    }

    // Note: write is synchronous because it's non-blocking
    // and some losiness is acceptable and increseases performance
    // since we don't block the reading loops.
    pub fn write(&self, packet: Packet<'_>) -> io::Result<usize> {
        match packet {
            Packet::Ipv4(msg) => self.0.get_ref().write4(&msg),
            Packet::Ipv6(msg) => self.0.get_ref().write6(&msg),
        }
    }
}

pub(super) async fn create_iface(
    config: &Interface,
    callbacks: &impl Callbacks<Error = Error>,
    fallback_strategy: DnsFallbackStrategy,
) -> Result<Device> {
    let (iface, stream) = IfaceDevice::new(config, callbacks, fallback_strategy).await?;
    iface.up().await?;
    let io = DeviceIo(stream);
    let mtu = AtomicUsize::new(ioctl::interface_mtu_by_name(iface.name())?);

    Ok(Device { io, mtu, iface })
}

pub(crate) mod ioctl {
    use super::*;

    pub(crate) fn interface_mtu_by_name(name: &str) -> Result<usize> {
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
    pub(crate) unsafe fn exec<P>(fd: RawFd, code: libc::c_ulong, req: &Request<P>) -> Result<()> {
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
