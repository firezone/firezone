use crate::device_channel::ioctl;
use crate::FIREZONE_MARK;
use connlib_shared::{
    linux::{etc_resolv_conf, DnsControlMethod},
    messages::Interface as InterfaceConfig,
    Callbacks, Error, Result,
};
use futures::TryStreamExt;
use futures_util::future::BoxFuture;
use futures_util::FutureExt;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use libc::{
    close, fcntl, makedev, mknod, open, F_GETFL, F_SETFL, IFF_MULTI_QUEUE, IFF_NO_PI, IFF_TUN,
    O_NONBLOCK, O_RDWR, S_IFCHR,
};
use netlink_packet_route::route::{RouteProtocol, RouteScope};
use netlink_packet_route::rule::RuleAction;
use rtnetlink::{new_connection, Error::NetlinkError, Handle};
use rtnetlink::{RouteAddRequest, RuleAddRequest};
use std::collections::HashSet;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
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
const DEFAULT_MTU: u32 = 1280;
const FILE_ALREADY_EXISTS: i32 = -17;
const FIREZONE_TABLE: u32 = 0x2021_fd00;

// Safety: We know that this is a valid C string.
const TUN_FILE: &CStr = unsafe { CStr::from_bytes_with_nul_unchecked(b"/dev/net/tun\0") };

pub struct Tun {
    handle: Handle,
    connection: tokio::task::JoinHandle<()>,
    fd: AsyncFd<RawFd>,

    worker: Option<BoxFuture<'static, Result<()>>>,
    routes: HashSet<IpNetwork>,
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

    pub fn poll_read(&mut self, buf: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        if let Some(worker) = self.worker.as_mut() {
            match worker.poll_unpin(cx) {
                Poll::Ready(Ok(())) => {
                    self.worker = None;
                }
                Poll::Ready(Err(e)) => {
                    self.worker = None;
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
        tracing::debug!(?dns_config);

        // TODO: Tech debt: <https://github.com/firezone/firezone/issues/3636>
        // TODO: Gateways shouldn't set up DNS, right? Only clients?
        // TODO: Move this configuration up to the client
        let dns_control_method = connlib_shared::linux::get_dns_control_from_env();
        tracing::info!(?dns_control_method);

        create_tun_device()?;

        let fd = match unsafe { open(TUN_FILE.as_ptr() as _, O_RDWR) } {
            -1 => return Err(get_last_error()),
            fd => fd,
        };

        // Safety: We just opened the file descriptor.
        unsafe {
            ioctl::exec(
                fd,
                TUNSETIFF,
                &mut ioctl::Request::<SetTunFlagsPayload>::new(),
            )?;
        }

        set_non_blocking(fd)?;

        let (connection, handle, _) = new_connection()?;
        let join_handle = tokio::spawn(connection);

        Ok(Self {
            handle: handle.clone(),
            connection: join_handle,
            fd: AsyncFd::new(fd)?,
            worker: Some(
                set_iface_config(config.clone(), dns_config, handle, dns_control_method).boxed(),
            ),
            routes: HashSet::new(),
        })
    }

    pub fn set_routes(&mut self, new_routes: HashSet<IpNetwork>, _: &impl Callbacks) -> Result<()> {
        if new_routes == self.routes {
            return Ok(());
        }

        let handle = self.handle.clone();
        let current_routes = self.routes.clone();
        self.routes = new_routes.clone();

        let set_routes_worker = async move {
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

            for route in new_routes.difference(&current_routes) {
                add_route(route, index, &handle).await;
            }

            for route in current_routes.difference(&new_routes) {
                delete_route(route, index, &handle).await;
            }

            Ok(())
        };

        match self.worker.take() {
            None => self.worker = Some(set_routes_worker.boxed()),
            Some(current_worker) => {
                self.worker = Some(
                    async move {
                        current_worker.await?;
                        set_routes_worker.await?;

                        Ok(())
                    }
                    .boxed(),
                )
            }
        }

        Ok(())
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
    dns_control_method: Option<DnsControlMethod>,
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

    if res_v4.is_ok() {
        if let Err(e) = make_rule(&handle).v4().execute().await {
            if !matches!(&e, NetlinkError(err) if err.raw_code() == FILE_ALREADY_EXISTS) {
                tracing::warn!(
                    "Couldn't add ip rule for ipv4: {e:?}, ipv4 packets won't be routed"
                );
            }
            // TODO: Be smarter about this
        } else {
            tracing::debug!("Successfully created ip rule for ipv4");
        }
    }

    if res_v6.is_ok() {
        if let Err(e) = make_rule(&handle).v6().execute().await {
            if !matches!(&e, NetlinkError(err) if err.raw_code() == FILE_ALREADY_EXISTS) {
                tracing::warn!(
                    "Couldn't add ip rule for ipv6: {e:?}, ipv6 packets won't be routed"
                );
            }
            // TODO: Be smarter about this
        } else {
            tracing::debug!("Successfully created ip rule for ipv6");
        }
    }

    res_v4.or(res_v6)?;

    match dns_control_method {
        None => {}
        Some(DnsControlMethod::EtcResolvConf) => etc_resolv_conf::configure(&dns_config).await.map_err(|e| Error::ResolvConf(e))?,
        Some(DnsControlMethod::NetworkManager) => configure_network_manager(&dns_config).await?,
        Some(DnsControlMethod::Systemd) => configure_systemd_resolved(&dns_config).await?,
    }

    // TODO: Having this inside the library is definitely wrong. I think `set_iface_config`
    // needs to return before `new` returns, so that the `on_tunnel_ready` callback
    // happens after the IP address and DNS are set up. Then we can call `sd_notify`
    // inside `on_tunnel_ready` in the client.
    //
    // `sd_notify::notify` is always safe to call, it silently returns `Ok(())`
    // if we aren't running as a systemd service.
    if let Err(error) = sd_notify::notify(true, &[sd_notify::NotifyState::Ready]) {
        // Nothing we can do about it
        tracing::warn!(?error, "Failed to notify systemd that we're ready");
    }

    Ok(())
}

fn make_rule(handle: &Handle) -> RuleAddRequest {
    let mut rule = handle
        .rule()
        .add()
        .fw_mark(FIREZONE_MARK)
        .table_id(FIREZONE_TABLE)
        .action(RuleAction::ToTable);

    rule.message_mut()
        .header
        .flags
        .push(netlink_packet_route::rule::RuleFlag::Invert);

    rule.message_mut()
        .attributes
        .push(netlink_packet_route::rule::RuleAttribute::Protocol(
            RouteProtocol::Kernel,
        ));

    rule
}

fn make_route(idx: u32, handle: &Handle) -> RouteAddRequest {
    handle
        .route()
        .add()
        .output_interface(idx)
        .protocol(RouteProtocol::Static)
        .scope(RouteScope::Universe)
        .table_id(FIREZONE_TABLE)
}

fn make_route_v4(idx: u32, handle: &Handle, route: Ipv4Network) -> RouteAddRequest<Ipv4Addr> {
    make_route(idx, handle)
        .v4()
        .destination_prefix(route.network_address(), route.netmask())
}

fn make_route_v6(idx: u32, handle: &Handle, route: Ipv6Network) -> RouteAddRequest<Ipv6Addr> {
    make_route(idx, handle)
        .v6()
        .destination_prefix(route.network_address(), route.netmask())
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

async fn add_route(route: &IpNetwork, idx: u32, handle: &Handle) {
    let res = match route {
        IpNetwork::V4(ipnet) => make_route_v4(idx, handle, *ipnet).execute().await,
        IpNetwork::V6(ipnet) => make_route_v6(idx, handle, *ipnet).execute().await,
    };

    match res {
        Ok(_) => {}
        Err(NetlinkError(err)) if err.raw_code() == FILE_ALREADY_EXISTS => {}
        // TODO: we should be able to surface this error and handle it depending on
        // if any of the added routes succeeded.
        Err(err) => {
            tracing::error!(%route, "failed to add route: {err}");
        }
    }
}

async fn delete_route(route: &IpNetwork, idx: u32, handle: &Handle) {
    let message = match route {
        IpNetwork::V4(ipnet) => make_route_v4(idx, handle, *ipnet).message_mut().clone(),
        IpNetwork::V6(ipnet) => make_route_v6(idx, handle, *ipnet).message_mut().clone(),
    };

    if let Err(err) = handle.route().del(message).execute().await {
        tracing::error!(%route, "failed to add route: {err:#?}");
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

async fn configure_network_manager(_dns_config: &[IpAddr]) -> Result<()> {
    Err(Error::Other(
        "DNS control with NetworkManager is not implemented yet",
    ))
}

async fn configure_systemd_resolved(dns_config: &[IpAddr]) -> Result<()> {
    let status = tokio::process::Command::new("resolvectl")
        .arg("dns")
        .arg(IFACE_NAME)
        .args(dns_config.iter().map(ToString::to_string))
        .status()
        .await
        .map_err(|_| Error::ResolvectlFailed)?;
    if !status.success() {
        return Err(Error::ResolvectlFailed);
    }

    let status = tokio::process::Command::new("resolvectl")
        .arg("domain")
        .arg(IFACE_NAME)
        .arg("~.")
        .status()
        .await
        .map_err(|_| Error::ResolvectlFailed)?;
    if !status.success() {
        return Err(Error::ResolvectlFailed);
    }

    tracing::info!(?dns_config, "Configured DNS sentinels with `resolvectl`");

    Ok(())
}

#[repr(C)]
struct SetTunFlagsPayload {
    flags: std::ffi::c_short,
}
