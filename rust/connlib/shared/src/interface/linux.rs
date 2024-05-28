//! Virtual network interface

use crate::linux::{etc_resolv_conf, DnsControlMethod};
use anyhow::{anyhow, bail, Context as _, Result};
use connlib_client_shared::{Cidrv4, Cidrv6};
use futures::TryStreamExt;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use netlink_packet_route::route::{RouteProtocol, RouteScope};
use netlink_packet_route::rule::RuleAction;
use rtnetlink::{new_connection, Error::NetlinkError, Handle, RouteAddRequest, RuleAddRequest};
use std::{
    collections::HashSet,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
};

// TODO: De-dupe before merging
const FIREZONE_MARK: u32 = 0xfd002021;
const IFACE_NAME: &str = "tun-firezone";
const DEFAULT_MTU: u32 = 1280;
const FILE_ALREADY_EXISTS: i32 = -17;
const FIREZONE_TABLE: u32 = 0x2021_fd00;

/// For lack of a better name
pub struct InterfaceManager {
    // This gets lazy-initialized when the interface is first configured
    connection: Option<Connection>,
    dns_control_method: Option<DnsControlMethod>,
    routes: HashSet<IpNetwork>,
}

struct Connection {
    handle: Handle,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for InterfaceManager {
    fn drop(&mut self) {
        if let Some(connection) = self.connection.take() {
            connection.task.abort();
        }
        tracing::debug!("Reverting DNS control...");
        if let Some(DnsControlMethod::EtcResolvConf) = self.dns_control_method {
            // TODO: Check that nobody else modified the file while we were running.
            etc_resolv_conf::revert().ok();
        }
    }
}

impl Default for InterfaceManager {
    fn default() -> Self {
        let dns_control_method = crate::linux::get_dns_control_from_env();
        tracing::info!(?dns_control_method);

        Self {
            connection: None,
            dns_control_method,
            routes: Default::default(),
        }
    }
}

impl InterfaceManager {
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn on_set_interface_config(
        &mut self,
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        dns_config: Vec<IpAddr>,
    ) -> Result<()> {
        let connection = match self.connection.as_mut() {
            None => {
                let (cxn, handle, _) = new_connection()?;
                let task = tokio::spawn(cxn);
                let connection = Connection { handle, task };
                self.connection.insert(connection)
            }
            Some(x) => x,
        };

        let handle = &connection.handle;
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

    // Fallible on Windows
    #[allow(clippy::unnecessary_wraps)]
    pub async fn control_dns(&self, dns_config: Vec<IpAddr>) -> Result<()> {
        if let Err(error) = match self.dns_control_method {
            None => Ok(()),
            Some(DnsControlMethod::EtcResolvConf) => etc_resolv_conf::configure(&dns_config).await,
            Some(DnsControlMethod::NetworkManager) => configure_network_manager(&dns_config),
            Some(DnsControlMethod::Systemd) => configure_systemd_resolved(&dns_config).await,
        } {
            tracing::error!("Failed to control DNS: {error}");
            panic!("Failed to control DNS: {error}");
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

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn on_update_routes(&mut self, ipv4: Vec<Cidrv4>, ipv6: Vec<Cidrv6>) -> Result<()> {
        let new_routes: HashSet<IpNetwork> = ipv4
            .into_iter()
            .map(|x| Into::<Ipv4Network>::into(x).into())
            .chain(
                ipv6.into_iter()
                    .map(|x| Into::<Ipv6Network>::into(x).into()),
            )
            .collect();
        if new_routes == self.routes {
            return Ok(());
        }
        tracing::info!(?new_routes, "on_update_routes");
        let handle = &self.connection.as_ref().ok_or_else(|| anyhow!("on_update_routes should only be called after at least one call to on_set_interface_config"))?.handle;

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
            add_route(route, index, handle).await;
        }

        for route in self.routes.difference(&new_routes) {
            delete_route(route, index, handle).await;
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

fn configure_network_manager(_dns_config: &[IpAddr]) -> Result<()> {
    Err(anyhow!(
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
        .context("`resolvectl dns` didn't run")?;
    if !status.success() {
        bail!("`resolvectl dns` returned non-zero");
    }

    let status = tokio::process::Command::new("resolvectl")
        .arg("domain")
        .arg(IFACE_NAME)
        .arg("~.")
        .status()
        .await
        .context("`resolvectl domain` didn't run")?;
    if !status.success() {
        bail!("`resolvectl domain` returned non-zero");
    }

    tracing::info!(?dns_config, "Configured DNS sentinels with `resolvectl`");

    Ok(())
}
