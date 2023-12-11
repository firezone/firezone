use crate::device_channel::ioctl;
use connlib_shared::{messages::Interface as InterfaceConfig, Callbacks, Error, Result};
use futures::TryStreamExt;
use futures_util::future::BoxFuture;
use futures_util::FutureExt;
use ip_network::IpNetwork;
use libc::{
    close, fcntl, open, F_GETFL, F_SETFL, IFF_MULTI_QUEUE, IFF_NO_PI, IFF_TUN, O_NONBLOCK, O_RDWR,
};
use netlink_packet_route::RT_SCOPE_UNIVERSE;
use parking_lot::Mutex;
use rtnetlink::{new_connection, Error::NetlinkError, Handle};
use std::task::{ready, Context, Poll};
use std::{
    fmt, io,
    os::fd::{AsRawFd, RawFd},
};
use tokio::io::unix::AsyncFd;
use tokio::io::Ready;

pub(crate) const SIOCGIFMTU: libc::c_ulong = libc::SIOCGIFMTU;

const IFACE_NAME: &str = "tun-firezone";
const TUNSETIFF: u64 = 0x4004_54ca;
const TUN_FILE: &[u8] = b"/dev/net/tun\0";
const RT_PROT_STATIC: u8 = 4;
const DEFAULT_MTU: u32 = 1280;
const FILE_ALREADY_EXISTS: i32 = -17;

pub struct Tun {
    handle: Handle,
    connection: tokio::task::JoinHandle<()>,
    interface_index: u32,
    fd: AsyncFd<RawFd>,

    worker: Mutex<Option<BoxFuture<'static, Result<()>>>>,
}

impl fmt::Debug for Tun {
    fn fmt(&self, _: &mut fmt::Formatter<'_>) -> fmt::Result {
        todo!()
    }
}

impl Drop for Tun {
    fn drop(&mut self) {
        unsafe { close(self.fd.as_raw_fd()) };
        self.connection.abort();
    }
}

impl Tun {
    pub fn write4(&self, buf: &[u8]) -> io::Result<usize> {
        write(self.fd.as_raw_fd(), buf)
    }

    pub fn write6(&self, buf: &[u8]) -> io::Result<usize> {
        write(self.fd.as_raw_fd(), buf)
    }

    pub fn poll_read(&self, buf: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        let mut guard = self.worker.lock();
        if let Some(worker) = guard.as_mut() {
            match worker.poll_unpin(cx) {
                Poll::Ready(Ok(())) => {
                    *guard = None;
                }
                Poll::Ready(Err(e)) => {
                    *guard = None;
                    return Poll::Ready(Err(io::Error::new(io::ErrorKind::Other, e)));
                }
                Poll::Pending => return Poll::Pending,
            }
        }

        loop {
            let mut guard = ready!(self.fd.poll_read_ready(cx))?;

            match read(guard.get_inner().as_raw_fd(), buf) {
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

    pub fn new(config: &InterfaceConfig, _: &impl Callbacks) -> Result<Self> {
        let fd = match unsafe { open(TUN_FILE.as_ptr() as _, O_RDWR) } {
            -1 => return Err(get_last_error()),
            fd => fd,
        };

        let request = ioctl::Request::<GetInterfaceIndexRequestPayload>::new();

        // Safety: We just opened the file descriptor.
        unsafe {
            dbg!(ioctl::exec(
                fd,
                TUNSETIFF,
                &ioctl::Request::<SetTunFlagsPayload>::new()
            ))?;
            dbg!(ioctl::exec(fd, libc::SIOCGIFINDEX, &request))?;
        }

        set_non_blocking(fd)?;
        let interface_index = request.index();

        let (connection, handle, _) = new_connection()?;
        let join_handle = tokio::spawn(connection);

        Ok(Self {
            handle: handle.clone(),
            connection: join_handle,
            interface_index,
            fd: AsyncFd::new(fd)?,
            worker: Mutex::new(Some(
                set_iface_config(config.clone(), handle, interface_index).boxed(),
            )),
        })
    }

    pub fn add_route(&self, route: IpNetwork, _: &impl Callbacks) -> Result<Option<Self>> {
        let handle = self.handle.clone();
        let index = self.interface_index;

        let add_route_worker = async move {
            let req = handle
                .route()
                .add()
                .output_interface(index)
                .protocol(RT_PROT_STATIC)
                .scope(RT_SCOPE_UNIVERSE);
            let res = match route {
                IpNetwork::V4(ipnet) => {
                    req.v4()
                        .destination_prefix(ipnet.network_address(), ipnet.netmask())
                        .execute()
                        .await
                }
                IpNetwork::V6(ipnet) => {
                    req.v6()
                        .destination_prefix(ipnet.network_address(), ipnet.netmask())
                        .execute()
                        .await
                }
            };

            match res {
                Ok(_) => Ok(()),
                Err(NetlinkError(err)) if err.raw_code() == FILE_ALREADY_EXISTS => Ok(()),
                Err(err) => Err(err.into()),
            }
        };

        let mut guard = self.worker.lock();
        match guard.take() {
            None => *guard = Some(add_route_worker.boxed()),
            Some(current_worker) => {
                *guard = Some(
                    async move {
                        current_worker.await?;
                        add_route_worker.await?;

                        Ok(())
                    }
                    .boxed(),
                )
            }
        }

        Ok(None)
    }

    pub fn name(&self) -> &str {
        IFACE_NAME
    }
}

#[tracing::instrument(level = "trace", skip(handle))]
async fn set_iface_config(config: InterfaceConfig, handle: Handle, index: u32) -> Result<()> {
    let ips = handle
        .address()
        .get()
        .set_link_index_filter(index)
        .execute();

    ips.try_for_each(|ip| handle.address().del(ip).execute())
        .await?;

    handle.link().set(index).mtu(DEFAULT_MTU).execute().await?;

    let res_v4 = handle
        .address()
        .add(index, config.ipv4.into(), 32)
        .execute()
        .await;
    let res_v6 = handle
        .address()
        .add(index, config.ipv6.into(), 128)
        .execute()
        .await;

    handle.link().set(index).up().execute().await?;

    Ok(res_v4.or(res_v6)?)
}

fn get_last_error() -> Error {
    Error::Io(io::Error::last_os_error())
}

fn set_non_blocking(fd: RawFd) -> Result<()> {
    match unsafe { fcntl(fd, F_GETFL) } {
        -1 => Err(get_last_error()),
        flags => match unsafe { fcntl(fd, F_SETFL, flags | O_NONBLOCK) } {
            -1 => Err(get_last_error()),
            _ => Ok(()),
        },
    }
}

/// Read from the given file descriptor in the buffer.
fn read(fd: RawFd, dst: &mut [u8]) -> io::Result<usize> {
    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::read(fd, dst.as_mut_ptr() as _, dst.len()) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}

/// Write the buffer to the given file descriptor.
fn write(fd: RawFd, buf: &[u8]) -> io::Result<usize> {
    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::write(fd, buf.as_ptr() as _, buf.len() as _) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}

impl ioctl::Request<SetTunFlagsPayload> {
    fn new() -> Self {
        let name_as_bytes = IFACE_NAME.as_bytes();
        debug_assert!(name_as_bytes.len() < libc::IF_NAMESIZE);

        let mut name = [0u8; libc::IF_NAMESIZE];
        name[..name_as_bytes.len()].copy_from_slice(name_as_bytes);

        Self {
            name,
            payload: SetTunFlagsPayload {
                flags: (IFF_TUN | IFF_NO_PI | IFF_MULTI_QUEUE) as _,
            },
        }
    }
}

#[repr(C)]
struct SetTunFlagsPayload {
    flags: std::ffi::c_short,
}

impl ioctl::Request<GetInterfaceIndexRequestPayload> {
    fn new() -> Self {
        let name_as_bytes = IFACE_NAME.as_bytes();
        debug_assert!(name_as_bytes.len() < libc::IF_NAMESIZE);

        let mut name = [0u8; libc::IF_NAMESIZE];
        name[..name_as_bytes.len()].copy_from_slice(name_as_bytes);

        Self {
            name,
            payload: GetInterfaceIndexRequestPayload::default(),
        }
    }

    fn index(&self) -> u32 {
        self.payload.index as _
    }
}

#[derive(Default)]
#[repr(C)]
struct GetInterfaceIndexRequestPayload {
    index: std::ffi::c_uint,
}
