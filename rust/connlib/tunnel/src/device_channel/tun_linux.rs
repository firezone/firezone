use crate::device_channel::ioctl;
use connlib_shared::{messages::Interface as InterfaceConfig, Callbacks, Error, Result};
use futures::TryStreamExt;
use futures_util::future::BoxFuture;
use futures_util::FutureExt;
use ip_network::IpNetwork;
use libc::{
    close, fcntl, makedev, mknod, open, F_GETFL, F_SETFL, IFF_MULTI_QUEUE, IFF_NO_PI, IFF_TUN,
    O_NONBLOCK, O_RDWR, S_IFCHR,
};
use netlink_packet_route::RT_SCOPE_UNIVERSE;
use parking_lot::Mutex;
use rtnetlink::{new_connection, Error::NetlinkError, Handle};
use std::net::IpAddr;
use std::path::Path;
use std::task::{Context, Poll};
use std::{
    ffi::CStr,
    fmt, fs, io,
    os::{
        fd::{AsRawFd, RawFd},
        unix::fs::PermissionsExt,
    },
};
use tokio::io::unix::AsyncFd;

mod utils;

pub(crate) const SIOCGIFMTU: libc::c_ulong = libc::SIOCGIFMTU;

const IFACE_NAME: &str = "tun-firezone";
const TUNSETIFF: libc::c_ulong = 0x4004_54ca;
const TUN_DEV_MAJOR: u32 = 10;
const TUN_DEV_MINOR: u32 = 200;
const RT_PROT_STATIC: u8 = 4;
const DEFAULT_MTU: u32 = 1280;
const FILE_ALREADY_EXISTS: i32 = -17;

// Safety: We know that this is a valid C string.
const TUN_FILE: &CStr = unsafe { CStr::from_bytes_with_nul_unchecked(b"/dev/net/tun\0") };

pub struct Tun {
    handle: Handle,
    connection: tokio::task::JoinHandle<()>,
    fd: AsyncFd<RawFd>,

    worker: Mutex<Option<BoxFuture<'static, Result<()>>>>,
}

impl fmt::Debug for Tun {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Tun")
            .field("handle", &self.handle)
            .field("connection", &self.connection)
            .field("fd", &self.fd)
            .finish_non_exhaustive()
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

        utils::poll_raw_fd(&self.fd, |fd| read(fd, buf), cx)
    }

    pub fn new(
        config: &InterfaceConfig,
        dns_config: Vec<IpAddr>,
        _: &impl Callbacks,
    ) -> Result<Self> {
        create_tun_device()?;

        let fd = match unsafe { open(TUN_FILE.as_ptr() as _, O_RDWR) } {
            -1 => return Err(get_last_error()),
            fd => fd,
        };

        // Safety: We just opened the file descriptor.
        unsafe {
            ioctl::exec(fd, TUNSETIFF, &ioctl::Request::<SetTunFlagsPayload>::new())?;
        }

        set_non_blocking(fd)?;

        let (connection, handle, _) = new_connection()?;
        let join_handle = tokio::spawn(connection);

        Ok(Self {
            handle: handle.clone(),
            connection: join_handle,
            fd: AsyncFd::new(fd)?,
            worker: Mutex::new(Some(
                set_iface_config(config.clone(), dns_config, handle).boxed(),
            )),
        })
    }

    pub fn add_route(&self, route: IpNetwork, _: &impl Callbacks) -> Result<Option<Self>> {
        let handle = self.handle.clone();

        let add_route_worker = async move {
            let index = handle
                .link()
                .get()
                .match_name(IFACE_NAME.to_string())
                .execute()
                .try_next()
                .await?
                .ok_or(Error::NoIface)?
                .header
                .index;

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
                // TODO: we should be able to surface this error and handle it depending on
                // if any of the added routes succeeded.
                Err(err) => {
                    tracing::error!(%route, "failed to add route: {err:#?}");
                    Ok(())
                }
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
async fn set_iface_config(
    config: InterfaceConfig,
    dns_config: Vec<IpAddr>,
    handle: Handle,
) -> Result<()> {
    let index = handle
        .link()
        .get()
        .match_name(IFACE_NAME.to_string())
        .execute()
        .try_next()
        .await?
        .ok_or(Error::NoIface)?
        .header
        .index;

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

    res_v4.or(res_v6)?;

    // IIRC the tunnel code also runs on gateways, which shouldn't have DNS set,
    // since they don't make any outgoing connections through Firezone?
    // And it would conflict if a client and gateway ran on the same system.
    if !dns_config.is_empty() {
        // TODO: Try to eliminate
        flush_dns().await?;

        // TODO: Fix before merging
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;

        configure_systemd_resolved(&dns_config).await?;
    }

    Ok(())
}

async fn flush_dns() -> Result<()> {
    // Flush systemd's DNS cache so resources like ifconfig.net will switch to
    // Firezone even if they were cached
    //
    // This doesn't fix a problem where systemd-resolved doesn't mark 100.100.111.1
    // as Firezone"s "Current DNS Server" until any transaction has happened.
    //
    // e.g., this will fail:
    //
    // 1. Start Firezone
    // 2. Confirm the "DNS Servers" in `resolvectl status` are good
    // 3. Run `resolvectl flush-caches` many times over any length of time
    // 4. Run `curl https://ifconfig.net/ip`
    //
    // It will still go outside the tunnel. But this will work:
    //
    // 1. Start Firezone
    // 2. Let `curl https://ifconfig.net/ip` fail once
    // 3. Run `resolvectl flush-caches` once
    // 4. Run `curl https://ifconfig.net/ip` again and it works
    let status = tokio::process::Command::new("resolvectl")
        .arg("flush-caches")
        .status()
        .await
        .map_err(|_| Error::ResolveCtlFlushCaches)?;
    if !status.success() {
        return Err(Error::ResolveCtlFlushCachesExitCode);
    }
    tracing::info!("Ran `resolvectl flush-caches`");
    Ok(())
}

async fn configure_systemd_resolved(dns_config: &[IpAddr]) -> Result<()> {
    // Set our DNS server for the tunnel interface
    // If I run this before the flush it doesn't work?
    // Does it work after the flush?
    let mut cmd = tokio::process::Command::new("resolvectl");
    cmd.arg("dns").arg(IFACE_NAME);
    for addr in dns_config {
        cmd.arg(addr.to_string());
    }
    let status = cmd.status().await.map_err(|_| Error::ResolveCtlSetDns)?;
    if !status.success() {
        return Err(Error::ResolveCtlSetDnsExitCode);
    }
    tracing::info!(?dns_config, "Ran `resolvectl dns`");

    // Tell systemd we can resolve any domain
    // TODO: If we want true split DNS we can move this over to `on_update_resources`
    let status = tokio::process::Command::new("resolvectl")
        .arg("domain")
        .arg(IFACE_NAME)
        .arg("~.")
        .status()
        .await
        .map_err(|_| Error::ResolveCtlSetDomains)?;
    if !status.success() {
        return Err(Error::ResolveCtlSetDomainsExitCode);
    }
    tracing::info!("Ran `resolvectl domain`");

    Ok(())
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

fn create_tun_device() -> Result<()> {
    let path = Path::new(TUN_FILE.to_str().expect("path is valid utf-8"));

    if path.exists() {
        return Ok(());
    }

    let parent_dir = path.parent().unwrap();
    fs::create_dir_all(parent_dir)?;
    let permissions = fs::Permissions::from_mode(0o751);
    fs::set_permissions(parent_dir, permissions)?;
    if unsafe {
        mknod(
            TUN_FILE.as_ptr() as _,
            S_IFCHR,
            makedev(TUN_DEV_MAJOR, TUN_DEV_MINOR),
        )
    } != 0
    {
        return Err(get_last_error());
    }

    Ok(())
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
