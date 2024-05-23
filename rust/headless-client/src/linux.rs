//! Implementation, Linux-specific

use super::{CliCommon, FIREZONE_GROUP, TOKEN_ENV_KEY};
use anyhow::{anyhow, bail, Context as _, Result};
use connlib_client_shared::{file_logger, Cidrv4, Cidrv6};
use connlib_shared::linux::{etc_resolv_conf, get_dns_control_from_env, DnsControlMethod};
use firezone_cli_utils::setup_global_subscriber;
use futures::TryStreamExt;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use netlink_packet_route::route::{RouteProtocol, RouteScope};
use netlink_packet_route::rule::RuleAction;
use rtnetlink::{new_connection, Error::NetlinkError, Handle, RouteAddRequest, RuleAddRequest};
use std::{
    collections::HashSet,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    str::FromStr,
    task::{Context, Poll},
};
use tokio::{
    net::{UnixListener, UnixStream},
    signal::unix::SignalKind as TokioSignalKind,
};

const FIREZONE_MARK: u32 = 0xfd002021;

// The Client currently must run as root to control DNS
// Root group and user are used to check file ownership on the token
const ROOT_GROUP: u32 = 0;
const ROOT_USER: u32 = 0;

// TODO: De-dupe before merging
const IFACE_NAME: &str = "tun-firezone";
const DEFAULT_MTU: u32 = 1280;
const FILE_ALREADY_EXISTS: i32 = -17;
const FIREZONE_TABLE: u32 = 0x2021_fd00;

pub(crate) struct Signals {
    sighup: tokio::signal::unix::Signal,
    sigint: tokio::signal::unix::Signal,
}

impl Signals {
    pub(crate) fn new() -> Result<Self> {
        let sighup = tokio::signal::unix::signal(TokioSignalKind::hangup())?;
        let sigint = tokio::signal::unix::signal(TokioSignalKind::interrupt())?;

        Ok(Self { sighup, sigint })
    }

    pub(crate) fn poll(&mut self, cx: &mut Context) -> Poll<super::SignalKind> {
        if self.sigint.poll_recv(cx).is_ready() {
            return Poll::Ready(super::SignalKind::Interrupt);
        }

        if self.sighup.poll_recv(cx).is_ready() {
            return Poll::Ready(super::SignalKind::Hangup);
        }

        Poll::Pending
    }
}

pub fn default_token_path() -> PathBuf {
    PathBuf::from("/etc")
        .join(connlib_shared::BUNDLE_ID)
        .join("token")
}

pub(crate) fn check_token_permissions(path: &Path) -> Result<()> {
    let Ok(stat) = nix::sys::stat::fstatat(None, path, nix::fcntl::AtFlags::empty()) else {
        // File doesn't exist or can't be read
        tracing::info!(
            ?path,
            ?TOKEN_ENV_KEY,
            "No token found in env var or on disk"
        );
        bail!("Token file doesn't exist");
    };
    if stat.st_uid != ROOT_USER {
        bail!(
            "Token file `{}` should be owned by root user",
            path.display()
        );
    }
    if stat.st_gid != ROOT_GROUP {
        bail!(
            "Token file `{}` should be owned by root group",
            path.display()
        );
    }
    if stat.st_mode & 0o177 != 0 {
        bail!(
            "Token file `{}` should have mode 0o400 or 0x600",
            path.display()
        );
    }
    Ok(())
}

pub(crate) fn system_resolvers() -> Result<Vec<IpAddr>> {
    match get_dns_control_from_env() {
        None => get_system_default_resolvers_resolv_conf(),
        Some(DnsControlMethod::EtcResolvConf) => get_system_default_resolvers_resolv_conf(),
        Some(DnsControlMethod::NetworkManager) => get_system_default_resolvers_network_manager(),
        Some(DnsControlMethod::Systemd) => get_system_default_resolvers_systemd_resolved(),
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

#[allow(clippy::unnecessary_wraps)]
fn get_system_default_resolvers_network_manager() -> Result<Vec<IpAddr>> {
    tracing::error!("get_system_default_resolvers_network_manager not implemented yet");
    Ok(vec![])
}

/// Returns the DNS servers listed in `resolvectl dns`
pub fn get_system_default_resolvers_systemd_resolved() -> Result<Vec<IpAddr>> {
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

/// The path for our Unix Domain Socket
///
/// Docker keeps theirs in `/run` and also appears to use filesystem permissions
/// for security, so we're following their lead. `/run` and `/var/run` are symlinked
/// on some systems, `/run` should be the newer version.
///
/// Also systemd can create this dir with the `RuntimeDir=` directive which is nice.
pub fn sock_path() -> PathBuf {
    PathBuf::from("/run")
        .join(connlib_shared::BUNDLE_ID)
        .join("ipc.sock")
}

/// Cross-platform entry point for systemd / Windows services
///
/// Linux uses the CLI args from here, Windows does not
pub(crate) fn run_ipc_service(cli: CliCommon) -> Result<()> {
    tracing::info!("run_ipc_service");
    // systemd supplies this but maybe we should hard-code a better default
    let (layer, _handle) = cli.log_dir.as_deref().map(file_logger::layer).unzip();
    setup_global_subscriber(layer);
    tracing::info!(git_version = crate::GIT_VERSION);

    if !nix::unistd::getuid().is_root() {
        anyhow::bail!("This is the IPC service binary, it's not meant to run interactively.");
    }
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(async { crate::ipc_listen().await })
}

pub fn firezone_group() -> Result<nix::unistd::Group> {
    let group = nix::unistd::Group::from_name(FIREZONE_GROUP)
        .context("can't get group by name")?
        .with_context(|| format!("`{FIREZONE_GROUP}` group must exist on the system"))?;
    Ok(group)
}

pub(crate) struct IpcServer {
    listener: UnixListener,
}

/// Opaque wrapper around platform-specific IPC stream
pub(crate) type IpcStream = UnixStream;

impl IpcServer {
    /// Platform-specific setup
    pub(crate) async fn new() -> Result<Self> {
        // Remove the socket if a previous run left it there
        let sock_path = sock_path();
        tokio::fs::remove_file(&sock_path).await.ok();
        let listener = UnixListener::bind(&sock_path).context("Couldn't bind UDS")?;
        let perms = std::fs::Permissions::from_mode(0o660);
        std::fs::set_permissions(sock_path, perms)?;
        tracing::info!("Listening for GUI to connect over IPC...");
        sd_notify::notify(true, &[sd_notify::NotifyState::Ready])?;
        Ok(Self { listener })
    }

    pub(crate) async fn next_client(&mut self) -> Result<IpcStream> {
        let (stream, _) = self.listener.accept().await?;
        let cred = stream.peer_cred()?;
        // I'm not sure if we can enforce group membership here - Docker
        // might just be enforcing it with filesystem permissions.
        // Checking the secondary groups of another user looks complicated.
        tracing::info!(
            uid = cred.uid(),
            gid = cred.gid(),
            pid = cred.pid(),
            "Got an IPC connection"
        );
        Ok(stream)
    }
}

/// Platform-specific setup needed for connlib
///
/// On Linux this does nothing
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn setup_before_connlib() -> Result<()> {
    Ok(())
}

/// For lack of a better name
pub(crate) struct InterfaceManager {
    connection: tokio::task::JoinHandle<()>,
    dns_control_method: Option<DnsControlMethod>,
    handle: Handle,
    routes: HashSet<IpNetwork>,
}

impl Drop for InterfaceManager {
    fn drop(&mut self) {
        self.connection.abort();
        tracing::debug!("Reverting DNS control...");
        if let Some(DnsControlMethod::EtcResolvConf) = self.dns_control_method {
            // TODO: Check that nobody else modified the file while we were running.
            etc_resolv_conf::revert().ok();
        }
    }
}

impl InterfaceManager {
    pub(crate) fn new() -> Result<Self> {
        let (connection, handle, _) = new_connection()?;
        let connection = tokio::spawn(connection);

        let dns_control_method = connlib_shared::linux::get_dns_control_from_env();
        tracing::info!(?dns_control_method);

        Ok(Self {
            connection,
            dns_control_method,
            handle,
            routes: Default::default(),
        })
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub(crate) async fn on_set_interface_config(
        &mut self,
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        dns_config: Vec<IpAddr>,
    ) -> Result<()> {
        let handle = &self.handle;
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
    pub(crate) async fn on_update_routes(
        &mut self,
        ipv4: Vec<Cidrv4>,
        ipv6: Vec<Cidrv6>,
    ) -> Result<()> {
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
        let handle = &self.handle;

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
