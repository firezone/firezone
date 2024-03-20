use anyhow::{Context, Result};
use clap::Parser;
use connlib_client_shared::{file_logger, Callbacks, Session};
use connlib_shared::{
    keypair,
    linux::{etc_resolv_conf, get_dns_control_from_env, DnsControlMethod},
    LoginUrl,
};
use firezone_cli_utils::{setup_global_subscriber, CommonArgs};
use firezone_tunnel::Tun;
use netlink_packet_route::route::{RouteProtocol, RouteScope};
use netlink_packet_route::rule::RuleAction;
use rtnetlink::{new_connection, Error::NetlinkError, Handle};
use rtnetlink::{RouteAddRequest, RuleAddRequest};
use secrecy::SecretString;
use std::{
    future,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    path::PathBuf,
    str::FromStr,
    task::Poll,
};
use tokio::signal::unix::SignalKind;

const IFACE_NAME: &str = "tun-firezone";
const DEFAULT_MTU: u32 = 1280;
const FILE_ALREADY_EXISTS: i32 = -17;
const FIREZONE_TABLE: u32 = 0x2021_fd00;

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let max_partition_time = cli.max_partition_time.map(|d| d.into());

    let (layer, handle) = cli.log_dir.as_deref().map(file_logger::layer).unzip();
    setup_global_subscriber(layer);

    let (connection, netlink_handle, _) = new_connection()?;
    tokio::spawn(connection);

    let dns_control_method = get_dns_control_from_env();
    let callbacks = CallbackHandler {
        dns_control_method: dns_control_method.clone(),
        handle,
        netlink_handle,
    };

    // AKA "Device ID", not the Firezone slug
    let firezone_id = match cli.firezone_id {
        Some(id) => id,
        None => connlib_shared::device_id::get().context("Could not get `firezone_id` from CLI, could not read it from disk, could not generate it and save it to disk")?.id,
    };

    let (private_key, public_key) = keypair();
    let login = LoginUrl::client(
        cli.common.api_url,
        &SecretString::from(cli.common.token),
        firezone_id,
        None,
        public_key.to_bytes(),
    )?;

    let mut session = Session::connect(
        login,
        private_key,
        None,
        callbacks,
        max_partition_time,
        tokio::runtime::Handle::current(),
    )
    .unwrap();
    session.update_tun(Tun::new(IFACE_NAME)?);

    let mut sigint = tokio::signal::unix::signal(SignalKind::interrupt())?;
    let mut sighup = tokio::signal::unix::signal(SignalKind::hangup())?;

    future::poll_fn(|cx| loop {
        if sigint.poll_recv(cx).is_ready() {
            tracing::debug!("Received SIGINT");

            return Poll::Ready(());
        }

        if sighup.poll_recv(cx).is_ready() {
            tracing::debug!("Received SIGHUP");

            session.reconnect();
            continue;
        }

        return Poll::Pending;
    })
    .await;

    session.disconnect();

    Ok(())
}

#[derive(Clone)]
struct CallbackHandler {
    dns_control_method: Option<DnsControlMethod>,
    handle: Option<file_logger::Handle>,

    netlink_handle: Handle,
}

impl Callbacks for CallbackHandler {
    /// May return Firezone's own servers, e.g. `100.100.111.1`.
    fn get_system_default_resolvers(&self) -> Option<Vec<IpAddr>> {
        let maybe_resolvers = match self.dns_control_method {
            None => get_system_default_resolvers_resolv_conf(),
            Some(DnsControlMethod::EtcResolvConf) => get_system_default_resolvers_resolv_conf(),
            Some(DnsControlMethod::NetworkManager) => {
                get_system_default_resolvers_network_manager()
            }
            Some(DnsControlMethod::Systemd) => get_system_default_resolvers_systemd_resolved(),
        };

        let resolvers = match maybe_resolvers {
            Ok(resolvers) => resolvers,
            Err(e) => {
                tracing::error!("Failed to get system default resolvers: {e}");
                return None;
            }
        };

        tracing::info!(?resolvers);

        Some(resolvers)
    }

    fn on_disconnect(&self, error: &connlib_client_shared::Error) {
        tracing::error!("Disconnected: {error}");

        std::process::exit(1);
    }

    fn roll_log_file(&self) -> Option<PathBuf> {
        self.handle
            .as_ref()?
            .roll_to_new_file()
            .unwrap_or_else(|e| {
                tracing::debug!("Failed to roll over to new file: {e}");
                None
            })
    }

    fn on_set_interface_config(
        &self,
        ip4: std::net::Ipv4Addr,
        ip6: std::net::Ipv6Addr,
        dns_servers: Vec<IpAddr>,
    ) {
        tokio::spawn(set_iface_config(
            ip4,
            ip6,
            dns_servers,
            self.netlink_handle.clone(),
            self.dns_control_method,
        ));
    }

    fn on_update_routes(&self, _: Vec<connlib_shared::Cidrv4>, _: Vec<connlib_shared::Cidrv6>) {
        tokio::spawn(set_routes(self.netlink_handle.clone()));
    }
}

async fn set_routes(handle: Handle) -> Result<()> {
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
}

#[tracing::instrument(level = "trace", skip(handle))]
async fn set_iface_config(
    ipv4: std::net::Ipv4Addr,
    ipv6: std::net::Ipv6Addr,
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

    handle.link().set(index).mtu(1280).execute().await?;

    let res_v4 = handle.address().add(index, ipv4.into(), 32).execute().await;
    let res_v6 = handle
        .address()
        .add(index, ipv6.into(), 128)
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
        Some(DnsControlMethod::EtcResolvConf) => {
            etc_resolv_conf::configure_dns(&dns_config).await?
        }
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

fn get_system_default_resolvers_resolv_conf() -> Result<Vec<IpAddr>> {
    // Assume that `configure_resolv_conf` has run in `tun_linux.rs`

    let s = std::fs::read_to_string(etc_resolv_conf::ETC_RESOLV_CONF_BACKUP)
        .or_else(|_| std::fs::read_to_string(etc_resolv_conf::ETC_RESOLV_CONF))
        .context("`resolv.conf` should be readable")?;
    let parsed = resolv_conf::Config::parse(s).context("`resolv.conf` should be parsable")?;

    // Drop the scoping info for IPv6 since connlib doesn't take it
    let nameservers = parsed
        .nameservers
        .into_iter()
        .map(|addr| addr.into())
        .collect();
    Ok(nameservers)
}

fn get_system_default_resolvers_network_manager() -> Result<Vec<IpAddr>> {
    tracing::error!("get_system_default_resolvers_network_manager not implemented yet");
    Ok(vec![])
}

/// Returns the DNS servers listed in `resolvectl dns`
fn get_system_default_resolvers_systemd_resolved() -> Result<Vec<IpAddr>> {
    // Unfortunately systemd-resolved does not have a machine-readable
    // text output for this command: <https://github.com/systemd/systemd/issues/29755>
    //
    // The officially supported way is probably to use D-Bus.
    let output = std::process::Command::new("resolvectl")
        .arg("dns")
        .output()
        .context("Failed to run `resolvectl dns` and read output")?;
    if !output.status.success() {
        anyhow::bail!("`resolvectl dns` returned non-zero exit code");
    }
    let output = String::from_utf8(output.stdout).context("`resolvectl` output was not UTF-8")?;
    Ok(parse_resolvectl_output(&output))
}

/// Parses the text output of `resolvectl dns`
///
/// Cannot fail. If the parsing code is wrong, the IP address vec will just be incomplete.
fn parse_resolvectl_output(s: &str) -> Vec<IpAddr> {
    s.lines()
        .flat_map(|line| line.split(' '))
        .filter_map(|word| IpAddr::from_str(word).ok())
        .collect()
}

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(flatten)]
    common: CommonArgs,

    /// Identifier used by the portal to identify and display the device.
    ///
    /// AKA `device_id` in the Windows and Linux GUI clients
    #[arg(short = 'i', long, env = "FIREZONE_ID")]
    pub firezone_id: Option<String>,

    /// File logging directory. Should be a path that's writeable by the current user.
    #[arg(short, long, env = "LOG_DIR")]
    log_dir: Option<PathBuf>,

    /// Maximum length of time to retry connecting to the portal if we're having internet issues or
    /// it's down. Accepts human times. e.g. "5m" or "1h" or "30d".
    #[arg(short, long, env = "MAX_PARTITION_TIME")]
    max_partition_time: Option<humantime::Duration>,
}

#[cfg(test)]
mod tests {
    use std::net::IpAddr;

    #[test]
    fn parse_resolvectl_output() {
        let cases = [
            // WSL
            (
                r"Global: 172.24.80.1
Link 2 (eth0):
Link 3 (docker0):
Link 24 (br-fc0b71997a3c):
Link 25 (br-0c129dafb204):
Link 26 (br-e67e83b19dce):
",
                [IpAddr::from([172, 24, 80, 1])],
            ),
            // Ubuntu 20.04
            (
                r"Global:
Link 2 (enp0s3): 192.168.1.1",
                [IpAddr::from([192, 168, 1, 1])],
            ),
        ];

        for (i, (input, expected)) in cases.iter().enumerate() {
            let actual = super::parse_resolvectl_output(input);
            assert_eq!(actual, expected, "Case {i} failed");
        }
    }
}
