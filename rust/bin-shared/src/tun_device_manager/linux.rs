//! Virtual network interface

use crate::FIREZONE_MARK;
use anyhow::{anyhow, Context as _, Result};
use firezone_logging::std_dyn_err;
use futures::{SinkExt, TryStreamExt};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_packet::{IpPacket, IpPacketBuf};
use libc::{
    fcntl, makedev, mknod, open, EEXIST, ENOENT, ESRCH, F_GETFL, F_SETFL, O_NONBLOCK, O_RDWR,
    S_IFCHR,
};
use netlink_packet_route::route::{RouteProtocol, RouteScope};
use netlink_packet_route::rule::RuleAction;
use rtnetlink::{new_connection, Error::NetlinkError, Handle, RouteAddRequest, RuleAddRequest};
use std::path::Path;
use std::task::{Context, Poll};
use std::{
    collections::HashSet,
    net::{Ipv4Addr, Ipv6Addr},
};
use std::{
    ffi::CStr,
    fs, io,
    os::{fd::RawFd, unix::fs::PermissionsExt},
};
use tokio::sync::mpsc;
use tun::ioctl;
use tun::unix::TunFd;

const TUNSETIFF: libc::c_ulong = 0x4004_54ca;
const TUN_DEV_MAJOR: u32 = 10;
const TUN_DEV_MINOR: u32 = 200;

const TUN_FILE: &CStr = c"/dev/net/tun";

const FIREZONE_TABLE: u32 = 0x2021_fd00;

/// For lack of a better name
pub struct TunDeviceManager {
    mtu: u32,
    num_threads: usize,
    connection: Connection,
    routes: HashSet<IpNetwork>,
}

struct Connection {
    handle: Handle,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for TunDeviceManager {
    fn drop(&mut self) {
        self.connection.task.abort();
    }
}

impl TunDeviceManager {
    pub const IFACE_NAME: &'static str = "tun-firezone";

    /// Creates a new managed tunnel device.
    ///
    /// Panics if called without a Tokio runtime.
    pub fn new(mtu: usize, num_threads: usize) -> Result<Self> {
        let (cxn, handle, _) = new_connection().context("Failed to create netlink connection")?;
        let task = tokio::spawn(cxn);
        let connection = Connection { handle, task };

        Ok(Self {
            connection,
            routes: Default::default(),
            mtu: mtu as u32,
            num_threads,
        })
    }

    pub fn make_tun(&mut self) -> Result<Tun> {
        Ok(Tun::new(self.num_threads)?)
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_ips(&mut self, ipv4: Ipv4Addr, ipv6: Ipv6Addr) -> Result<()> {
        let name = Self::IFACE_NAME;

        let handle = &self.connection.handle;
        let index = handle
            .link()
            .get()
            .match_name(name.to_string())
            .execute()
            .try_next()
            .await?
            .ok_or_else(|| anyhow!("Interface '{name}' does not exist"))?
            .header
            .index;

        let ips = handle
            .address()
            .get()
            .set_link_index_filter(index)
            .execute();

        ips.try_for_each(|ip| handle.address().del(ip).execute())
            .await
            .context("Failed to delete existing addresses")?;

        handle
            .link()
            .set(index)
            .mtu(self.mtu)
            .execute()
            .await
            .context("Failed to set default MTU")?;

        let res_v4 = handle.address().add(index, ipv4.into(), 32).execute().await;
        let res_v6 = handle
            .address()
            .add(index, ipv6.into(), 128)
            .execute()
            .await;

        handle
            .link()
            .set(index)
            .up()
            .execute()
            .await
            .context("Failed to bring up interface")?;

        if res_v4.is_ok() {
            if let Err(e) = make_rule(handle).v4().execute().await {
                if !matches!(&e, NetlinkError(err) if err.raw_code() == -EEXIST) {
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
            if let Err(e) = make_rule(handle).v6().execute().await {
                if !matches!(&e, NetlinkError(err) if err.raw_code() == -EEXIST) {
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

        Ok(())
    }

    pub async fn set_routes(
        &mut self,
        ipv4: Vec<Ipv4Network>,
        ipv6: Vec<Ipv6Network>,
    ) -> Result<()> {
        let new_routes: HashSet<IpNetwork> = ipv4
            .into_iter()
            .map(IpNetwork::from)
            .chain(ipv6.into_iter().map(IpNetwork::from))
            .collect();

        tracing::info!(?new_routes, "Setting new routes");

        let handle = &self.connection.handle;

        let index = handle
            .link()
            .get()
            .match_name(Self::IFACE_NAME.to_string())
            .execute()
            .try_next()
            .await?
            .context("No interface")?
            .header
            .index;

        for route in self.routes.difference(&new_routes) {
            remove_route(route, index, handle).await;
        }

        for route in &new_routes {
            add_route(route, index, handle).await;
        }

        self.routes = new_routes;
        Ok(())
    }
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

async fn add_route(route: &IpNetwork, idx: u32, handle: &Handle) {
    let res = match route {
        IpNetwork::V4(ipnet) => make_route_v4(idx, handle, *ipnet).execute().await,
        IpNetwork::V6(ipnet) => make_route_v6(idx, handle, *ipnet).execute().await,
    };

    let Err(err) = res else {
        tracing::debug!(%route, iface_idx = %idx, "Created new route");

        return;
    };

    // We expect this to be called often with an already existing route since set_routes always calls for all routes
    if matches!(&err, NetlinkError(err) if err.raw_code() == -EEXIST) {
        return;
    }

    // On systems without support for a certain IP version (i.e. no IPv6), attempting to add a route may result in "Not supported (os error 95)".
    if matches!(&err, NetlinkError(err) if err.raw_code() == -libc::EOPNOTSUPP) {
        return;
    }

    tracing::warn!(error = std_dyn_err(&err), %route, "Failed to add route");
}

async fn remove_route(route: &IpNetwork, idx: u32, handle: &Handle) {
    let message = match route {
        IpNetwork::V4(ipnet) => make_route_v4(idx, handle, *ipnet).message_mut().clone(),
        IpNetwork::V6(ipnet) => make_route_v6(idx, handle, *ipnet).message_mut().clone(),
    };

    let res = handle.route().del(message).execute().await;

    let Err(err) = res else {
        tracing::debug!(%route, iface_idx = %idx, "Removed route");

        return;
    };

    // Our view of the current routes may be stale. Removing a route that no longer exists shouldn't print a warning.
    if matches!(&err, NetlinkError(err) if err.raw_code() == -ENOENT) {
        return;
    }

    // "No such process" is another version of "route does not exist".
    // See <https://askubuntu.com/questions/1330333/what-causes-rtnetlink-answers-no-such-process-when-using-ifdown-command>.
    if matches!(&err, NetlinkError(err) if err.raw_code() == ESRCH) {
        return;
    }

    tracing::warn!(error = std_dyn_err(&err), %route, "Failed to remove route");
}

#[derive(Debug)]
pub struct Tun {
    outbound_tx: flume::r#async::SendSink<'static, IpPacket>,
    inbound_rx: mpsc::Receiver<IpPacket>,
}

impl Tun {
    pub fn new(num_threads: usize) -> io::Result<Self> {
        create_tun_device()?;

        let (inbound_tx, inbound_rx) = mpsc::channel(1000);
        let (outbound_tx, outbound_rx) = flume::bounded(1000); // flume is an MPMC channel, therefore perfect for workstealing outbound packets.

        for n in 0..num_threads {
            let fd = open_tun()?;
            let outbound_rx = outbound_rx.clone().into_stream();
            let inbound_tx = inbound_tx.clone();

            std::thread::Builder::new()
                .name(format!("TUN send/recv {n}/{num_threads}"))
                .spawn(move || {
                    firezone_logging::unwrap_or_warn!(
                        tun::unix::send_recv_tun(
                            fd,
                            inbound_tx,
                            outbound_rx,
                            read,
                            write,
                        ),
                        "Failed to send / recv from TUN device"
                    )
                })
                .map_err(io::Error::other)?;
        }

        Ok(Self {
            outbound_tx: outbound_tx.into_sink(),
            inbound_rx,
        })
    }
}

fn open_tun() -> Result<TunFd, io::Error> {
    let fd = match unsafe { open(TUN_FILE.as_ptr() as _, O_RDWR) } {
        -1 => return Err(get_last_error()),
        fd => fd,
    };

    unsafe {
        ioctl::exec(
            fd,
            TUNSETIFF,
            &mut ioctl::Request::<ioctl::SetTunFlagsPayload>::new(TunDeviceManager::IFACE_NAME),
        )?;
    }

    set_non_blocking(fd)?;

    // Safety: We are not closing the FD.
    let fd = unsafe { TunFd::new(fd) };

    Ok(fd)
}

impl tun::Tun for Tun {
    fn poll_send_ready(&mut self, cx: &mut Context) -> Poll<io::Result<()>> {
        self.outbound_tx
            .poll_ready_unpin(cx)
            .map_err(io::Error::other)
    }

    fn send(&mut self, packet: IpPacket) -> io::Result<()> {
        self.outbound_tx
            .start_send_unpin(packet)
            .map_err(io::Error::other)?;

        Ok(())
    }

    fn poll_recv_many(
        &mut self,
        cx: &mut Context,
        buf: &mut Vec<IpPacket>,
        max: usize,
    ) -> Poll<usize> {
        self.inbound_rx.poll_recv_many(cx, buf, max)
    }

    fn name(&self) -> &str {
        TunDeviceManager::IFACE_NAME
    }
}

fn get_last_error() -> io::Error {
    io::Error::last_os_error()
}

fn set_non_blocking(fd: RawFd) -> io::Result<()> {
    match unsafe { fcntl(fd, F_GETFL) } {
        -1 => Err(get_last_error()),
        flags => match unsafe { fcntl(fd, F_SETFL, flags | O_NONBLOCK) } {
            -1 => Err(get_last_error()),
            _ => Ok(()),
        },
    }
}

fn create_tun_device() -> io::Result<()> {
    let path = Path::new(TUN_FILE.to_str().expect("path is valid utf-8"));

    if path.exists() {
        return Ok(());
    }

    let parent_dir = path
        .parent()
        .expect("const-declared path always has a parent");
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
fn read(fd: RawFd, dst: &mut IpPacketBuf) -> io::Result<usize> {
    let dst = dst.buf();

    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::read(fd, dst.as_mut_ptr() as _, dst.len()) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}

/// Write the packet to the given file descriptor.
fn write(fd: RawFd, packet: &IpPacket) -> io::Result<usize> {
    let buf = packet.packet();

    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::write(fd, buf.as_ptr() as _, buf.len() as _) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}
