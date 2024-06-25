//! Virtual network interface

use crate::{
    callbacks::{Cidrv4, Cidrv6},
    DEFAULT_MTU,
};
use anyhow::{anyhow, Context as _, Result};
use futures::TryStreamExt;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use netlink_packet_route::route::{RouteProtocol, RouteScope};
use netlink_packet_route::rule::RuleAction;
use rtnetlink::{new_connection, Error::NetlinkError, Handle, RouteAddRequest, RuleAddRequest};
use std::{
    collections::HashSet,
    net::{Ipv4Addr, Ipv6Addr},
};

pub const FIREZONE_MARK: u32 = 0xfd002021;
pub const IFACE_NAME: &str = "tun-firezone";
const FILE_ALREADY_EXISTS: i32 = -17;
const FIREZONE_TABLE: u32 = 0x2021_fd00;

/// For lack of a better name
pub struct TunDeviceManager {
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
    /// Creates a new managed tunnel device.
    ///
    /// Panics if called without a Tokio runtime.
    pub fn new() -> Result<Self> {
        let (cxn, handle, _) = new_connection()?;
        let task = tokio::spawn(cxn);
        let connection = Connection { handle, task };

        Ok(Self {
            connection,
            routes: Default::default(),
        })
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_ips(&mut self, ipv4: Ipv4Addr, ipv6: Ipv6Addr) -> Result<()> {
        let handle = &self.connection.handle;
        let index = handle
            .link()
            .get()
            .match_name(IFACE_NAME.to_string())
            .execute()
            .try_next()
            .await?
            .ok_or_else(|| anyhow!("No interface"))?
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

        let res_v4 = handle.address().add(index, ipv4.into(), 32).execute().await;
        let res_v6 = handle
            .address()
            .add(index, ipv6.into(), 128)
            .execute()
            .await;

        handle.link().set(index).up().execute().await?;

        if res_v4.is_ok() {
            if let Err(e) = make_rule(handle).v4().execute().await {
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
            if let Err(e) = make_rule(handle).v6().execute().await {
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

        Ok(())
    }

    pub async fn set_routes(&mut self, ipv4: Vec<Cidrv4>, ipv6: Vec<Cidrv6>) -> Result<()> {
        let new_routes: HashSet<IpNetwork> = ipv4
            .into_iter()
            .map(IpNetwork::from)
            .chain(ipv6.into_iter().map(IpNetwork::from))
            .collect();
        if new_routes == self.routes {
            tracing::debug!("Routes are unchanged");

            return Ok(());
        }

        tracing::info!(?new_routes, "Setting new routes");

        let handle = &self.connection.handle;

        let index = handle
            .link()
            .get()
            .match_name(IFACE_NAME.to_string())
            .execute()
            .try_next()
            .await?
            .context("No interface")?
            .header
            .index;

        for route in new_routes.difference(&self.routes) {
            add_route(route, index, handle).await?;
        }

        for route in self.routes.difference(&new_routes) {
            delete_route(route, index, handle).await?;
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

async fn add_route(route: &IpNetwork, idx: u32, handle: &Handle) -> Result<()> {
    let res = match route {
        IpNetwork::V4(ipnet) => make_route_v4(idx, handle, *ipnet).execute().await,
        IpNetwork::V6(ipnet) => make_route_v6(idx, handle, *ipnet).execute().await,
    };

    match res {
        Ok(_) => {}
        Err(NetlinkError(err)) if err.raw_code() == FILE_ALREADY_EXISTS => {}
        // TODO: we should be able to surface this error and handle it depending on
        // if any of the added routes succeeded.
        Err(err) => Err(err).context("Failed to add route")?,
    }
    Ok(())
}

async fn delete_route(route: &IpNetwork, idx: u32, handle: &Handle) -> Result<()> {
    let message = match route {
        IpNetwork::V4(ipnet) => make_route_v4(idx, handle, *ipnet).message_mut().clone(),
        IpNetwork::V6(ipnet) => make_route_v6(idx, handle, *ipnet).message_mut().clone(),
    };

    handle
        .route()
        .del(message)
        .execute()
        .await
        .context("Failed to delete route")?;
    Ok(())
}
