//! Virtual network interface

use crate::{FIREZONE_MARK, tun_device_manager::TunIpStack};
use anyhow::{Context as _, Result};
use futures::{
    SinkExt, StreamExt, TryStreamExt,
    future::{self, Either},
};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_packet::{IpPacket, IpPacketBuf};
use libc::{
    EEXIST, ENOENT, ESRCH, F_GETFL, F_SETFL, O_NONBLOCK, O_RDWR, S_IFCHR, fcntl, makedev, mknod,
    open,
};
use logging::{DisplayBTreeSet, err_with_src};
use netlink_packet_route::link::{LinkAttribute, State};
use netlink_packet_route::route::{
    RouteAddress, RouteAttribute, RouteMessage, RouteProtocol, RouteScope,
};
use netlink_packet_route::rule::RuleAction;
use rtnetlink::sys::AsyncSocket;
use rtnetlink::{Error::NetlinkError, Handle, RuleAddRequest, new_connection};
use rtnetlink::{LinkUnspec, RouteMessageBuilder};
use std::sync::Arc;
use std::task::{Context, Poll};
use std::{collections::BTreeSet, path::Path};
use std::{
    collections::HashMap,
    os::fd::{FromRawFd as _, OwnedFd},
};
use std::{
    collections::HashSet,
    net::{Ipv4Addr, Ipv6Addr},
};
use std::{
    ffi::CStr,
    fs, io,
    os::{fd::RawFd, unix::fs::PermissionsExt},
};
use std::{net::IpAddr, time::Duration};
use telemetry::otel;
use tokio::{sync::mpsc, time::Instant};
use tokio_util::sync::PollSender;
use tun::ioctl;

const TUNSETIFF: libc::c_ulong = 0x4004_54ca;
const TUN_DEV_MAJOR: u32 = 10;
const TUN_DEV_MINOR: u32 = 200;

const TUN_FILE: &CStr = c"/dev/net/tun";

const FIREZONE_TABLE_USER: u32 = 0x2021_fd00;
const FIREZONE_TABLE_LINK_SCOPE: u32 = 0x2021_fd01;
const FIREZONE_TABLE_INTERNET: u32 = 0x2021_fd02;

/// For lack of a better name
pub struct TunDeviceManager {
    mtu: u32,
    connection: Connection,
    routes: BTreeSet<IpNetwork>,
}

struct Connection {
    handle: Handle,
    connection_task: tokio::task::JoinHandle<()>,
    link_scope_route_sync_task: tokio::task::JoinHandle<()>,
}

impl Drop for TunDeviceManager {
    fn drop(&mut self) {
        self.connection.connection_task.abort();
        self.connection.link_scope_route_sync_task.abort();
    }
}

impl TunDeviceManager {
    pub const IFACE_NAME: &'static str = "tun-firezone";

    /// Creates a new managed tunnel device.
    ///
    /// Panics if called without a Tokio runtime.
    pub fn new(mtu: usize) -> Result<Self> {
        let (mut cxn, handle, messages) =
            new_connection().context("Failed to create netlink connection")?;

        tokio::spawn({
            let handle = handle.clone();

            async move {
                if let Err(e) = flush_routing_tables(handle.clone()).await {
                    tracing::debug!("Failed to flush routing tables: {e}")
                }
            }
        });

        subscribe_to_route_changes(&mut cxn)?;

        let connection = Connection {
            link_scope_route_sync_task: tokio::spawn(sync_link_scope_routes_worker(
                messages,
                handle.clone(),
            )),
            connection_task: tokio::spawn(cxn),
            handle,
        };

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
    pub async fn set_ips(&mut self, ipv4: Ipv4Addr, ipv6: Ipv6Addr) -> Result<TunIpStack> {
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
            match install_rules([
                make_rule(handle, FIREZONE_TABLE_USER, 100).v4(),
                make_rule(handle, FIREZONE_TABLE_LINK_SCOPE, 200).v4(),
                make_rule(handle, FIREZONE_TABLE_INTERNET, 300).v4(),
            ])
            .await
            {
                Ok(()) => tracing::debug!("Successfully created routing rules for IPv4"),
                Err(e) => tracing::warn!("Failed to add IPv4 routing rules: {e}"),
            }
        }

        if res_v6.is_ok() {
            match install_rules([
                make_rule(handle, FIREZONE_TABLE_USER, 100).v6(),
                make_rule(handle, FIREZONE_TABLE_LINK_SCOPE, 200).v6(),
                make_rule(handle, FIREZONE_TABLE_INTERNET, 300).v6(),
            ])
            .await
            {
                Ok(()) => tracing::debug!("Successfully created routing rules for IPv6"),
                Err(e) => tracing::warn!("Failed to add IPv6 routing rules: {e}"),
            }
        }

        let tun_ip_stack = match (res_v4, res_v6) {
            (Ok(()), Ok(())) => TunIpStack::Dual,
            (Ok(()), Err(e)) => {
                tracing::debug!("Failed to set IPv6 address on TUN device: {e}");

                TunIpStack::V4Only
            }
            (Err(e), Ok(())) => {
                tracing::debug!("Failed to set IPv4 address on TUN device: {e}");

                TunIpStack::V6Only
            }
            (Err(e_v4), Err(e_v6)) => {
                anyhow::bail!("Failed to set IPv4 and IPv6 address on TUN device: {e_v4} | {e_v6}")
            }
        };

        Ok(tun_ip_stack)
    }

    pub async fn set_routes(
        &mut self,
        ipv4: impl IntoIterator<Item = Ipv4Network>,
        ipv6: impl IntoIterator<Item = Ipv6Network>,
    ) -> Result<()> {
        let new_routes = ipv4
            .into_iter()
            .map(IpNetwork::from)
            .chain(ipv6.into_iter().map(IpNetwork::from))
            .collect::<BTreeSet<_>>();

        tracing::info!(new_routes = %DisplayBTreeSet(&new_routes), "Setting new routes");

        let handle = &self.connection.handle;
        let index = tun_device_index(handle).await?;

        for route in self.routes.difference(&new_routes) {
            let table = if is_default_route(route) {
                FIREZONE_TABLE_INTERNET
            } else {
                FIREZONE_TABLE_USER
            };

            remove_route(route, index, table, handle).await;
        }

        for route in &new_routes {
            let table = if is_default_route(route) {
                FIREZONE_TABLE_INTERNET
            } else {
                FIREZONE_TABLE_USER
            };

            add_route(route, index, table, handle).await;
        }

        self.routes = new_routes;
        Ok(())
    }
}

/// Worker function that triggers a link-scope route sync on every notification from netlink.
///
/// We add/remove routes one-by-one and a new notification is triggered for each.
/// To avoid unnecessary syncs, we debounce the sync by delaying its start by 500ms, resetting
/// the timer on each new notification.
async fn sync_link_scope_routes_worker(
    mut messages: futures::channel::mpsc::UnboundedReceiver<(
        netlink_packet_core::NetlinkMessage<netlink_packet_route::RouteNetlinkMessage>,
        rtnetlink::sys::SocketAddr,
    )>,
    handle: Handle,
) {
    let mut debounce_timer = Box::pin(tokio::time::sleep(Duration::MAX));

    loop {
        match future::select(messages.next(), debounce_timer.as_mut()).await {
            Either::Left((None, _)) => break,
            Either::Left((Some((message, _)), _)) => {
                // Check if this is a route/address/link change message
                let netlink_packet_core::NetlinkPayload::InnerMessage(_) = message.payload else {
                    continue;
                };

                debounce_timer
                    .as_mut()
                    .reset(Instant::now() + Duration::from_millis(500));
            }
            Either::Right((_, _)) => {
                if let Err(e) = sync_link_scope_routes(&handle).await {
                    tracing::debug!("Failed to sync link-scope routes: {e:#}");
                }

                // Reset to far future so it doesn't trigger again until a new message arrives
                debounce_timer = Box::pin(tokio::time::sleep(Duration::MAX));
            }
        }
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

fn make_rule(handle: &Handle, table: u32, priority: u32) -> RuleAddRequest {
    let mut rule = handle
        .rule()
        .add()
        .fw_mark(FIREZONE_MARK)
        .table_id(table)
        .priority(priority)
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

async fn install_rules<const N: usize, T>(
    requests: [RuleAddRequest<T>; N],
) -> Result<(), rtnetlink::Error> {
    for req in requests {
        match req.execute().await {
            Err(e) if matches!(&e, NetlinkError(err) if err.raw_code() == -EEXIST) => {}
            Err(e) => return Err(e),
            Ok(()) => {}
        }
    }

    Ok(())
}

async fn tun_device_index(handle: &Handle) -> Result<u32> {
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

fn make_route_v4(idx: u32, route: Ipv4Network, table: u32) -> RouteMessage {
    RouteMessageBuilder::<Ipv4Addr>::new()
        .output_interface(idx)
        .protocol(RouteProtocol::Static)
        .scope(RouteScope::Universe)
        .table_id(table)
        .destination_prefix(route.network_address(), route.netmask())
        .build()
}

fn make_route_v6(idx: u32, route: Ipv6Network, table: u32) -> RouteMessage {
    RouteMessageBuilder::<Ipv6Addr>::new()
        .output_interface(idx)
        .protocol(RouteProtocol::Static)
        .scope(RouteScope::Universe)
        .table_id(table)
        .destination_prefix(route.network_address(), route.netmask())
        .build()
}

async fn add_route(route: &IpNetwork, idx: u32, table: u32, handle: &Handle) {
    let message = match route {
        IpNetwork::V4(ipnet) => make_route_v4(idx, *ipnet, table),
        IpNetwork::V6(ipnet) => make_route_v6(idx, *ipnet, table),
    };

    execute_add_route_message(message, handle).await;
}

async fn remove_route(route: &IpNetwork, idx: u32, table: u32, handle: &Handle) {
    let message = match route {
        IpNetwork::V4(ipnet) => make_route_v4(idx, *ipnet, table),
        IpNetwork::V6(ipnet) => make_route_v6(idx, *ipnet, table),
    };

    execute_del_route_message(message, handle).await
}

async fn execute_add_route_message(message: RouteMessage, handle: &Handle) {
    let route = route_from_message(&message).map(tracing::field::display);
    let iface_idx = iface_index_from_message(&message).map(tracing::field::display);
    let table_id = table_id_from_message(&message);

    let Err(err) = handle.route().add(message).execute().await else {
        tracing::debug!(route, iface_idx, %table_id, "Created new route");

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
    let table_id = table_id_from_message(&message);

    let Err(err) = handle.route().del(message).execute().await else {
        tracing::debug!(route, iface_idx, %table_id, "Removed route");

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
fn table_id_from_message(message: &RouteMessage) -> u32 {
    message
        .attributes
        .iter()
        .find_map(|a| match a {
            RouteAttribute::Table(table) => Some(*table),
            _ => None,
        })
        .unwrap_or(message.header.table as u32)
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

async fn flush_routing_tables(handle: Handle) -> Result<()> {
    tracing::debug!("Flushing routing table");

    let routes = list_routes(&handle)
        .await?
        .into_iter()
        .filter(|r| {
            [
                FIREZONE_TABLE_USER,
                FIREZONE_TABLE_LINK_SCOPE,
                FIREZONE_TABLE_INTERNET,
            ]
            .contains(&table_id_from_message(r))
        })
        .collect::<Vec<_>>();

    for msg in routes {
        execute_del_route_message(msg, &handle).await;
    }

    Ok(())
}

fn subscribe_to_route_changes(
    cxn: &mut rtnetlink::proto::Connection<netlink_packet_route::RouteNetlinkMessage>,
) -> Result<(), anyhow::Error> {
    let groups = (libc::RTMGRP_IPV4_ROUTE
        | libc::RTMGRP_IPV6_ROUTE
        | libc::RTMGRP_LINK
        | libc::RTMGRP_IPV4_IFADDR
        | libc::RTMGRP_IPV6_IFADDR) as u32;

    cxn.socket_mut()
        .socket_mut()
        .bind(&rtnetlink::sys::SocketAddr::new(0, groups))
        .context("Failed to bind netlink socket for events")?;

    Ok(())
}

/// Sync link-scope routes from the main table to the Firezone routing table.
///
/// This ensures that directly-connected networks (like local LANs) bypass the tunnel.
async fn sync_link_scope_routes(handle: &Handle) -> Result<()> {
    tracing::debug!("Syncing link-scope routes to Firezone routing table");

    let link_scope_routes = list_routes(handle)
        .await?
        .into_iter()
        .filter(|route| route.header.scope == RouteScope::Link) // Only process link-scope routes
        .collect::<Vec<_>>();
    let link_states = link_states(handle, &link_scope_routes).await;

    let link_scope_routes_firezone_table = link_scope_routes
        .iter()
        .filter(|m| table_id_from_message(m) == FIREZONE_TABLE_LINK_SCOPE)
        .cloned()
        .collect::<Vec<_>>();

    let link_scope_routes_main_table = link_scope_routes
        .iter()
        .filter(|m| m.header.table == libc::RT_TABLE_MAIN)
        .filter(|m| {
            let Some(idx) = iface_index_from_message(m) else {
                return false;
            };

            let Some(link_state) = link_states.get(&idx).copied() else {
                return false;
            };

            let Some(route) = route_from_message(m) else {
                return false;
            };

            let is_up = link_state == State::Up;

            if !is_up {
                tracing::debug!(%route, "Skipping route because corresponding interface is not up");
            }

            is_up
        })
        .cloned()
        .collect::<Vec<_>>();

    if HashSet::<IpNetwork>::from_iter(
        link_scope_routes_firezone_table
            .iter()
            .filter_map(route_from_message),
    ) == HashSet::<IpNetwork>::from_iter(
        link_scope_routes_main_table
            .iter()
            .filter_map(route_from_message),
    ) {
        tracing::debug!("Link-scope routes in Firezone table are up-to-date");

        return Ok(());
    }

    // Now add all current link-scope routes from main table to Firezone table
    for mut message in link_scope_routes_main_table {
        // Change the table ID from main table to Firezone table
        message.header.table = libc::RT_TABLE_UNSPEC;
        message
            .attributes
            .retain(|a| !matches!(a, RouteAttribute::Table(_)));
        message
            .attributes
            .push(RouteAttribute::Table(FIREZONE_TABLE_LINK_SCOPE));

        execute_add_route_message(message, handle).await;
    }

    Ok(())
}

fn is_default_route(route: &IpNetwork) -> bool {
    match route {
        IpNetwork::V4(v4) => v4 == &Ipv4Network::DEFAULT_ROUTE,
        IpNetwork::V6(v6) => v6 == &Ipv6Network::DEFAULT_ROUTE,
    }
}

async fn list_routes(handle: &Handle) -> Result<Vec<RouteMessage>> {
    let all_routes = handle
        .route()
        .get(RouteMessageBuilder::<IpAddr>::new().build())
        .execute()
        .try_collect::<Vec<_>>()
        .await
        .context("Failed to get routes")?;

    Ok(all_routes)
}

#[expect(
    clippy::wildcard_enum_match_arm,
    reason = "We only want the `OperState` attribute."
)]
async fn link_states(handle: &Handle, link_scope_routes: &[RouteMessage]) -> HashMap<u32, State> {
    let mut link_state = HashMap::with_capacity(link_scope_routes.len());

    for idx in link_scope_routes
        .iter()
        .filter_map(iface_index_from_message)
    {
        let link_message = match handle
            .link()
            .get()
            .match_index(idx)
            .execute()
            .try_next()
            .await
        {
            Ok(Some(msg)) => msg,
            Ok(None) => {
                tracing::debug!(%idx, "Failed to get link state");
                link_state.insert(idx, State::Unknown);
                continue;
            }
            Err(e) => {
                tracing::debug!(%idx, "Failed to get link state: {e}");
                link_state.insert(idx, State::Unknown);
                continue;
            }
        };

        let state = link_message
            .attributes
            .iter()
            .find_map(|a| match a {
                LinkAttribute::OperState(state) => Some(*state),
                _ => None,
            })
            .unwrap_or(State::Unknown);

        link_state.insert(idx, state);
    }

    link_state
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
                    logging::unwrap_or_warn!(
                        tun::unix::tun_send(fd, outbound_rx, write),
                        "Failed to send to TUN device: {}"
                    )
                }
            })
            .map_err(io::Error::other)?;
        std::thread::Builder::new()
            .name("TUN recv".to_owned())
            .spawn(move || {
                logging::unwrap_or_warn!(
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
    let path = Path::new(TUN_FILE.to_str().map_err(io::Error::other)?);

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
