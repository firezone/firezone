//! Virtual network interface

use crate::FIREZONE_MARK;
use anyhow::{Context as _, Result};
use firezone_logging::err_with_src;
use firezone_telemetry::otel;
use futures::{SinkExt, TryStreamExt};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_packet::{IpPacket, IpPacketBuf};
use libc::{
    EEXIST, ENOENT, ESRCH, F_GETFL, F_SETFL, O_NONBLOCK, O_RDWR, S_IFCHR, fcntl, makedev, mknod,
    open,
};
use netlink_packet_route::link::LinkAttribute;
use netlink_packet_route::route::{
    RouteAddress, RouteAttribute, RouteMessage, RouteProtocol, RouteScope,
};
use netlink_packet_route::rule::RuleAction;
use rtnetlink::{Error::NetlinkError, Handle, RuleAddRequest, new_connection};
use rtnetlink::{LinkUnspec, RouteMessageBuilder};
use std::os::fd::{FromRawFd as _, OwnedFd};
use std::path::Path;
use std::sync::Arc;
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
use tokio_util::sync::PollSender;
use tun::ioctl;

const TUNSETIFF: libc::c_ulong = 0x4004_54ca;
const TUN_DEV_MAJOR: u32 = 10;
const TUN_DEV_MINOR: u32 = 200;

const TUN_FILE: &CStr = c"/dev/net/tun";

const FIREZONE_TABLE: u32 = 0x2021_fd00;

/// For lack of a better name
pub struct TunDeviceManager {
    mtu: u32,
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
    pub fn new(mtu: usize) -> Result<Self> {
        let (cxn, handle, _) = new_connection().context("Failed to create netlink connection")?;
        let task = tokio::spawn(cxn);
        let connection = Connection { handle, task };

        Ok(Self {
            connection,
            routes: Default::default(),
            mtu: mtu as u32,
        })
    }

    pub fn make_tun(&mut self) -> Result<Box<dyn tun::Tun>> {
        let tun = Box::new(Tun::new()?);

        // Do this in a separate task because:
        // a) We want it to be infallible.
        // b) We don't want `async` to creep into the API.
        tokio::spawn({
            let handle = self.connection.handle.clone();

            async move {
                if let Err(e) = set_txqueue_length(handle, 10_000).await {
                    tracing::warn!("Failed to set TX queue length: {e}")
                }
            }
        });

        Ok(tun)
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_ips(&mut self, ipv4: Ipv4Addr, ipv6: Ipv6Addr) -> Result<()> {
        let handle = &self.connection.handle;
        let index = tun_device_index(handle).await?;

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
            .set(LinkUnspec::new_with_index(index).mtu(self.mtu).build())
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
            .set(LinkUnspec::new_with_index(index).up().build())
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
        ipv4: impl IntoIterator<Item = Ipv4Network>,
        ipv6: impl IntoIterator<Item = Ipv6Network>,
    ) -> Result<()> {
        let new_routes: HashSet<IpNetwork> = ipv4
            .into_iter()
            .map(IpNetwork::from)
            .chain(ipv6.into_iter().map(IpNetwork::from))
            .collect();

        tracing::info!(?new_routes, "Setting new routes");

        let handle = &self.connection.handle;
        let index = tun_device_index(handle).await?;

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

async fn set_txqueue_length(handle: Handle, queue_len: u32) -> Result<()> {
    let index = tun_device_index(&handle).await?;

    handle
        .link()
        .set(
            LinkUnspec::new_with_index(index)
                .append_extra_attribute(LinkAttribute::TxQueueLen(queue_len))
                .build(),
        )
        .execute()
        .await?;

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
        .insert(netlink_packet_route::rule::RuleFlags::Invert);

    rule.message_mut()
        .attributes
        .push(netlink_packet_route::rule::RuleAttribute::Protocol(
            RouteProtocol::Kernel,
        ));

    rule
}

async fn tun_device_index(handle: &Handle) -> Result<u32, anyhow::Error> {
    let index = handle
        .link()
        .get()
        .match_name(TunDeviceManager::IFACE_NAME.to_string())
        .execute()
        .try_next()
        .await?
        .context("No interface")?
        .header
        .index;

    Ok(index)
}

fn make_route_v4(idx: u32, route: Ipv4Network) -> RouteMessage {
    RouteMessageBuilder::<Ipv4Addr>::new()
        .output_interface(idx)
        .protocol(RouteProtocol::Static)
        .scope(RouteScope::Universe)
        .table_id(FIREZONE_TABLE)
        .destination_prefix(route.network_address(), route.netmask())
        .build()
}

fn make_route_v6(idx: u32, route: Ipv6Network) -> RouteMessage {
    RouteMessageBuilder::<Ipv6Addr>::new()
        .output_interface(idx)
        .protocol(RouteProtocol::Static)
        .scope(RouteScope::Universe)
        .table_id(FIREZONE_TABLE)
        .destination_prefix(route.network_address(), route.netmask())
        .build()
}

async fn add_route(route: &IpNetwork, idx: u32, handle: &Handle) {
    let message = match route {
        IpNetwork::V4(ipnet) => make_route_v4(idx, *ipnet),
        IpNetwork::V6(ipnet) => make_route_v6(idx, *ipnet),
    };

    execute_add_route_message(message, handle).await;
}

async fn remove_route(route: &IpNetwork, idx: u32, handle: &Handle) {
    let message = match route {
        IpNetwork::V4(ipnet) => make_route_v4(idx, *ipnet),
        IpNetwork::V6(ipnet) => make_route_v6(idx, *ipnet),
    };

    execute_del_route_message(message, handle).await
}

async fn execute_add_route_message(message: RouteMessage, handle: &Handle) {
    let route = route_from_message(&message).map(tracing::field::display);
    let iface_idx = iface_index_from_message(&message).map(tracing::field::display);

    let Err(err) = handle.route().add(message).execute().await else {
        tracing::debug!(route, iface_idx, "Created new route");

        return;
    };

    // We expect this to be called often with an already existing route
    if matches!(&err, NetlinkError(err) if err.raw_code() == -EEXIST) {
        return;
    }

    // On systems without support for a certain IP version (i.e. no IPv6), attempting to add a route may result in "Not supported (os error 95)".
    if matches!(&err, NetlinkError(err) if err.raw_code() == -libc::EOPNOTSUPP) {
        return;
    }

    tracing::warn!(route, "Failed to add route: {}", err_with_src(&err));
}

async fn execute_del_route_message(message: RouteMessage, handle: &Handle) {
    let route = route_from_message(&message).map(tracing::field::display);
    let iface_idx = iface_index_from_message(&message).map(tracing::field::display);

    let Err(err) = handle.route().del(message).execute().await else {
        tracing::debug!(route, iface_idx, "Removed route");

        return;
    };

    // Our view of the current routes may be stale. Removing a route that no longer exists shouldn't print a warning.
    if matches!(&err, NetlinkError(err) if err.raw_code() == -ENOENT) {
        return;
    }

    // "No such process" is another version of "route does not exist".
    // See <https://askubuntu.com/questions/1330333/what-causes-rtnetlink-answers-no-such-process-when-using-ifdown-command>.
    if matches!(&err, NetlinkError(err) if err.raw_code() == -ESRCH) {
        return;
    }

    tracing::warn!(route, "Failed to remove route: {}", err_with_src(&err));
}

#[expect(
    clippy::wildcard_enum_match_arm,
    reason = "We don't want to match all attributes."
)]
fn iface_index_from_message(message: &RouteMessage) -> Option<u32> {
    message.attributes.iter().find_map(|a| match a {
        RouteAttribute::Oif(idx) => Some(*idx),
        _ => None,
    })
}

#[expect(
    clippy::wildcard_enum_match_arm,
    reason = "We don't want to match all attributes."
)]
fn route_from_message(message: &RouteMessage) -> Option<IpNetwork> {
    let netmask = message.header.destination_prefix_length;

    message.attributes.iter().find_map(|a| match a {
        RouteAttribute::Destination(RouteAddress::Inet(ipv4)) => {
            Some(IpNetwork::V4(Ipv4Network::new(*ipv4, netmask).ok()?))
        }
        RouteAttribute::Destination(RouteAddress::Inet6(ipv6)) => {
            Some(IpNetwork::V6(Ipv6Network::new(*ipv6, netmask).ok()?))
        }
        _ => None,
    })
}
const QUEUE_SIZE: usize = 10_000;

#[derive(Debug)]
pub struct Tun {
    outbound_tx: PollSender<IpPacket>,
    inbound_rx: mpsc::Receiver<IpPacket>,
}

impl Tun {
    pub fn new() -> Result<Self> {
        create_tun_device()?;

        let (inbound_tx, inbound_rx) = mpsc::channel(QUEUE_SIZE);
        let (outbound_tx, outbound_rx) = mpsc::channel(QUEUE_SIZE);

        tokio::spawn(otel::metrics::periodic_system_queue_length(
            outbound_tx.downgrade(),
            [
                otel::attr::queue_item_ip_packet(),
                otel::attr::network_io_direction_transmit(),
            ],
        ));
        tokio::spawn(otel::metrics::periodic_system_queue_length(
            inbound_tx.downgrade(),
            [
                otel::attr::queue_item_ip_packet(),
                otel::attr::network_io_direction_receive(),
            ],
        ));

        let fd = Arc::new(open_tun()?);

        std::thread::Builder::new()
            .name("TUN send".to_owned())
            .spawn({
                let fd = fd.clone();

                move || {
                    firezone_logging::unwrap_or_warn!(
                        tun::unix::tun_send(fd, outbound_rx, write),
                        "Failed to send to TUN device: {}"
                    )
                }
            })
            .map_err(io::Error::other)?;
        std::thread::Builder::new()
            .name("TUN recv".to_owned())
            .spawn(move || {
                firezone_logging::unwrap_or_warn!(
                    tun::unix::tun_recv(fd, inbound_tx, read),
                    "Failed to recv from TUN device: {}"
                )
            })
            .map_err(io::Error::other)?;

        Ok(Self {
            outbound_tx: PollSender::new(outbound_tx),
            inbound_rx,
        })
    }
}

fn open_tun() -> Result<OwnedFd> {
    let fd = match unsafe { open(TUN_FILE.as_ptr() as _, O_RDWR) } {
        -1 => {
            let file = TUN_FILE.to_str()?;

            return Err(anyhow::Error::new(get_last_error()))
                .with_context(|| format!("Failed to open '{file}'"));
        }
        fd => fd,
    };

    unsafe {
        ioctl::exec(
            fd,
            TUNSETIFF,
            &mut ioctl::Request::<ioctl::SetTunFlagsPayload>::new(TunDeviceManager::IFACE_NAME),
        )
        .context("Failed to set flags on TUN device")?;
    }

    set_non_blocking(fd).context("Failed to make TUN device non-blocking")?;

    // Safety: We are not closing the FD.
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };

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
