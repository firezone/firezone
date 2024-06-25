//! A library for the privileged tunnel process for a Linux Firezone Client
//!
//! This is built both standalone and as part of the GUI package. Building it
//! standalone is faster and skips all the GUI dependencies. We can use that build for
//! CLI use cases.
//!
//! Building it as a binary within the `gui-client` package allows the
//! Tauri deb bundler to pick it up easily.
//! Otherwise we would just make it a normal binary crate.

use anyhow::{anyhow, bail, Context as _, Result};
use clap::Parser;
use connlib_client_shared::{
    file_logger, keypair, Callbacks, ConnectArgs, Error as ConnlibError, LoginUrl, Session, Sockets,
};
use connlib_shared::{callbacks, tun_device_manager, Cidrv4, Cidrv6};
use firezone_cli_utils::setup_global_subscriber;
use futures::{future, SinkExt, StreamExt};
use secrecy::SecretString;
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    path::{Path, PathBuf},
    pin::pin,
    time::Duration,
};
use tokio::{sync::mpsc, time::Instant};
use tracing::subscriber::set_global_default;
use tracing_subscriber::{fmt, layer::SubscriberExt, EnvFilter, Layer, Registry};
use url::Url;

use platform::default_token_path;
/// SIGINT and, on Linux, SIGHUP.
///
/// Must be constructed inside a Tokio runtime context.
use platform::Signals;

/// Generate a persistent device ID, stores it to disk, and reads it back.
pub(crate) mod device_id;
pub mod dns_control;
pub mod heartbeat;
pub mod ipc;
pub mod known_dirs;

#[cfg(target_os = "linux")]
#[path = "linux.rs"]
pub mod platform;

#[cfg(target_os = "windows")]
#[path = "windows.rs"]
pub mod platform;

use dns_control::DnsController;
use ipc::{Server as IpcServer, ServiceId};

/// Only used on Linux
pub const FIREZONE_GROUP: &str = "firezone-client";

/// Output of `git describe` at compile time
/// e.g. `1.0.0-pre.4-20-ged5437c88-modified` where:
///
/// * `1.0.0-pre.4` is the most recent ancestor tag
/// * `20` is the number of commits since then
/// * `g` doesn't mean anything
/// * `ed5437c88` is the Git commit hash
/// * `-modified` is present if the working dir has any changes from that commit number
pub(crate) const GIT_VERSION: &str = git_version::git_version!(
    args = ["--always", "--dirty=-modified", "--tags"],
    fallback = "unknown"
);

/// Default log filter for the IPC service
#[cfg(debug_assertions)]
const SERVICE_RUST_LOG: &str = "firezone_headless_client=debug,firezone_tunnel=debug,phoenix_channel=debug,connlib_shared=debug,connlib_client_shared=debug,boringtun=debug,snownet=debug,str0m=info,info";

/// Default log filter for the IPC service
#[cfg(not(debug_assertions))]
const SERVICE_RUST_LOG: &str = "str0m=warn,info";

const TOKEN_ENV_KEY: &str = "FIREZONE_TOKEN";

/// Command-line args for the headless Client
#[derive(clap::Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    // Needed to preserve CLI arg compatibility
    // TODO: Remove
    #[command(subcommand)]
    _command: Option<Cmd>,

    #[command(flatten)]
    common: CliCommon,

    #[arg(
        short = 'u',
        long,
        hide = true,
        env = "FIREZONE_API_URL",
        default_value = "wss://api.firezone.dev"
    )]
    api_url: url::Url,

    /// Check the configuration and return 0 before connecting to the API
    ///
    /// Returns 1 if the configuration is wrong. Mostly non-destructive but may
    /// write a device ID to disk if one is not found.
    #[arg(long)]
    check: bool,

    /// Friendly name for this client to display in the UI.
    #[arg(long, env = "FIREZONE_NAME")]
    firezone_name: Option<String>,

    /// Identifier used by the portal to identify and display the device.

    // AKA `device_id` in the Windows and Linux GUI clients
    // Generated automatically if not provided
    #[arg(short = 'i', long, env = "FIREZONE_ID")]
    firezone_id: Option<String>,

    /// Token generated by the portal to authorize websocket connection.
    // systemd recommends against passing secrets through env vars:
    // <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#Environment=>
    #[arg(env = TOKEN_ENV_KEY, hide = true)]
    token: Option<String>,

    /// A filesystem path where the token can be found

    // Apparently passing secrets through stdin is the most secure method, but
    // until anyone asks for it, env vars are okay and files on disk are slightly better.
    // (Since we run as root and the env var on a headless system is probably stored
    // on disk somewhere anyway.)
    #[arg(default_value = default_token_path().display().to_string(), env = "FIREZONE_TOKEN_PATH", long)]
    token_path: PathBuf,
}

#[derive(clap::Parser)]
#[command(author, version, about, long_about = None)]
struct CliIpcService {
    #[command(subcommand)]
    command: CmdIpc,

    #[command(flatten)]
    common: CliCommon,
}

#[derive(clap::Subcommand, Debug, PartialEq, Eq)]
enum CmdIpc {
    /// Needed to test the IPC service on aarch64 Windows,
    /// where the Tauri MSI bundler doesn't work yet
    Install,
    Run,
    RunDebug,
}

impl Default for CmdIpc {
    fn default() -> Self {
        Self::Run
    }
}

/// CLI args common to both the IPC service and the headless Client
#[derive(clap::Args)]
struct CliCommon {
    /// File logging directory. Should be a path that's writeable by the current user.
    #[arg(short, long, env = "LOG_DIR")]
    log_dir: Option<PathBuf>,

    /// Maximum length of time to retry connecting to the portal if we're having internet issues or
    /// it's down. Accepts human times. e.g. "5m" or "1h" or "30d".
    #[arg(short, long, env = "MAX_PARTITION_TIME")]
    max_partition_time: Option<humantime::Duration>,
}

#[derive(clap::Subcommand, Clone, Copy)]
enum Cmd {
    #[command(hide = true)]
    IpcService,
    Standalone,
}

#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub enum IpcClientMsg {
    Connect { api_url: String, token: String },
    Disconnect,
    Reconnect,
    SetDns(Vec<IpAddr>),
}

enum InternalServerMsg {
    Ipc(IpcServerMsg),
    OnSetInterfaceConfig {
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        dns: Vec<IpAddr>,
    },
    OnUpdateRoutes {
        ipv4: Vec<Cidrv4>,
        ipv6: Vec<Cidrv6>,
    },
}

#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub enum IpcServerMsg {
    Ok,
    OnDisconnect {
        error_msg: String,
        is_authentication_error: bool,
    },
    OnTunnelReady,
    OnUpdateResources(Vec<callbacks::ResourceDescription>),
}

pub fn run_only_headless_client() -> Result<()> {
    let mut cli = Cli::try_parse()?;

    // Modifying the environment of a running process is unsafe. If any other
    // thread is reading or writing the environment, something bad can happen.
    // So `run` must take over as early as possible during startup, and
    // take the token env var before any other threads spawn.

    let token_env_var = cli.token.take().map(SecretString::from);
    let cli = cli;

    // Docs indicate that `remove_var` should actually be marked unsafe
    // SAFETY: We haven't spawned any other threads, this code should be the first
    // thing to run after entering `main` and parsing CLI args.
    // So nobody else is reading the environment.
    #[allow(unused_unsafe)]
    unsafe {
        // This removes the token from the environment per <https://security.stackexchange.com/a/271285>. We run as root so it may not do anything besides defense-in-depth.
        std::env::remove_var(TOKEN_ENV_KEY);
    }
    assert!(std::env::var(TOKEN_ENV_KEY).is_err());

    // TODO: This might have the same issue with fatal errors not getting logged
    // as addressed for the IPC service in PR #5216
    let (layer, _handle) = cli
        .common
        .log_dir
        .as_deref()
        .map(file_logger::layer)
        .unzip();
    setup_global_subscriber(layer);

    tracing::info!(git_version = crate::GIT_VERSION);

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;

    let token = get_token(token_env_var, &cli.token_path)?.with_context(|| {
        format!(
            "Can't find the Firezone token in ${TOKEN_ENV_KEY} or in `{}`",
            cli.token_path.display()
        )
    })?;
    tracing::info!("Running in headless / standalone mode");
    let _guard = rt.enter();
    // TODO: Should this default to 30 days?
    let max_partition_time = cli.common.max_partition_time.map(|d| d.into());

    // AKA "Device ID", not the Firezone slug
    let firezone_id = match cli.firezone_id {
        Some(id) => id,
        None => device_id::get_or_create().context("Could not get `firezone_id` from CLI, could not read it from disk, could not generate it and save it to disk")?.id,
    };

    let (private_key, public_key) = keypair();
    let url = LoginUrl::client(
        cli.api_url,
        &token,
        firezone_id,
        cli.firezone_name,
        public_key.to_bytes(),
    )?;

    if cli.check {
        tracing::info!("Check passed");
        return Ok(());
    }

    let (cb_tx, mut cb_rx) = mpsc::channel(10);
    let callbacks = CallbackHandler { cb_tx };

    platform::setup_before_connlib()?;
    let args = ConnectArgs {
        url,
        sockets: Sockets::new(),
        private_key,
        os_version_override: None,
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        callbacks,
        max_partition_time,
    };
    let session = Session::connect(args, rt.handle().clone());
    // TODO: this should be added dynamically
    session.set_dns(dns_control::system_resolvers().unwrap_or_default());
    platform::notify_service_controller()?;

    let result = rt.block_on(async {
        let mut dns_controller = dns_control::DnsController::default();
        let mut tun_device = tun_device_manager::TunDeviceManager::new()?;
        let mut signals = Signals::new()?;

        loop {
            match future::select(pin!(signals.recv()), pin!(cb_rx.recv())).await {
                future::Either::Left((SignalKind::Hangup, _)) => {
                    tracing::info!("Caught Hangup signal");
                    session.reconnect();
                }
                future::Either::Left((SignalKind::Interrupt, _)) => {
                    tracing::info!("Caught Interrupt signal");
                    return Ok(());
                }
                future::Either::Right((None, _)) => {
                    return Err(anyhow::anyhow!("cb_rx unexpectedly ran empty"));
                }
                future::Either::Right((Some(msg), _)) => match msg {
                    InternalServerMsg::Ipc(IpcServerMsg::OnDisconnect {
                        error_msg,
                        is_authentication_error: _,
                    }) => return Err(anyhow!(error_msg).context("Firezone disconnected")),
                    InternalServerMsg::Ipc(IpcServerMsg::Ok)
                    | InternalServerMsg::Ipc(IpcServerMsg::OnTunnelReady)
                    | InternalServerMsg::Ipc(IpcServerMsg::OnUpdateResources(_)) => {}
                    InternalServerMsg::OnSetInterfaceConfig { ipv4, ipv6, dns } => {
                        tun_device.set_ips(ipv4, ipv6).await?;
                        dns_controller.set_dns(&dns).await?;
                    }
                    InternalServerMsg::OnUpdateRoutes { ipv4, ipv6 } => {
                        tun_device.set_routes(ipv4, ipv6).await?
                    }
                },
            }
        }
    });

    session.disconnect();

    result
}

/// Only called from the GUI Client's build of the IPC service
pub fn run_only_ipc_service() -> Result<()> {
    // Docs indicate that `remove_var` should actually be marked unsafe
    // SAFETY: We haven't spawned any other threads, this code should be the first
    // thing to run after entering `main` and parsing CLI args.
    // So nobody else is reading the environment.
    #[allow(unused_unsafe)]
    unsafe {
        // This removes the token from the environment per <https://security.stackexchange.com/a/271285>. We run as root so it may not do anything besides defense-in-depth.
        std::env::remove_var(TOKEN_ENV_KEY);
    }
    assert!(std::env::var(TOKEN_ENV_KEY).is_err());
    let cli = CliIpcService::try_parse()?;
    match cli.command {
        CmdIpc::Install => platform::install_ipc_service(),
        CmdIpc::Run => platform::run_ipc_service(cli.common),
        CmdIpc::RunDebug => run_debug_ipc_service(),
    }
}

pub(crate) fn run_debug_ipc_service() -> Result<()> {
    setup_stdout_logging()?;
    let rt = tokio::runtime::Runtime::new()?;
    let _guard = rt.enter();
    rt.spawn(crate::heartbeat::heartbeat());
    let mut signals = Signals::new()?;

    // Couldn't get the loop to work here yet, so SIGHUP is not implemented
    rt.block_on(async {
        let ipc_service = pin!(ipc_listen());

        match future::select(pin!(signals.recv()), ipc_service).await {
            future::Either::Left((SignalKind::Hangup, _)) => {
                bail!("Exiting, SIGHUP not implemented for the IPC service");
            }
            future::Either::Left((SignalKind::Interrupt, _)) => {
                tracing::info!("Caught Interrupt signal");
                Ok(())
            }
            future::Either::Right((Ok(impossible), _)) => match impossible {},
            future::Either::Right((Err(error), _)) => Err(error).context("ipc_listen failed"),
        }
    })
}

#[derive(Clone)]
struct CallbackHandler {
    cb_tx: mpsc::Sender<InternalServerMsg>,
}

impl Callbacks for CallbackHandler {
    fn on_disconnect(&self, error: &connlib_client_shared::Error) {
        tracing::error!(?error, "Got `on_disconnect` from connlib");
        let is_authentication_error = if let ConnlibError::PortalConnectionFailed(error) = error {
            error.is_authentication_error()
        } else {
            false
        };
        self.cb_tx
            .try_send(InternalServerMsg::Ipc(IpcServerMsg::OnDisconnect {
                error_msg: error.to_string(),
                is_authentication_error,
            }))
            .expect("should be able to send OnDisconnect");
    }

    fn on_set_interface_config(
        &self,
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        dns: Vec<IpAddr>,
    ) -> Option<i32> {
        tracing::info!("TunnelReady (on_set_interface_config)");
        self.cb_tx
            .try_send(InternalServerMsg::OnSetInterfaceConfig { ipv4, ipv6, dns })
            .expect("Should be able to send TunnelReady");

        None
    }

    fn on_update_resources(&self, resources: Vec<callbacks::ResourceDescription>) {
        tracing::debug!(len = resources.len(), "New resource list");
        self.cb_tx
            .try_send(InternalServerMsg::Ipc(IpcServerMsg::OnUpdateResources(
                resources,
            )))
            .expect("Should be able to send OnUpdateResources");
    }

    fn on_update_routes(&self, ipv4: Vec<Cidrv4>, ipv6: Vec<Cidrv6>) -> Option<i32> {
        self.cb_tx
            .try_send(InternalServerMsg::OnUpdateRoutes { ipv4, ipv6 })
            .expect("Should be able to send messages");
        None
    }
}

async fn ipc_listen() -> Result<std::convert::Infallible> {
    // Create the device ID and IPC service config dir if needed
    // This also gives the GUI a safe place to put the log filter config
    device_id::get_or_create().context("Failed to read / create device ID")?;
    let mut server = IpcServer::new(ServiceId::Prod).await?;
    loop {
        dns_control::deactivate()?;
        let (rx, tx) = server
            .next_client_split()
            .await
            .context("Failed to wait for incoming IPC connection from a GUI")?;
        Handler::new(rx, tx)?.run().await;
    }
}

/// Handles one IPC client
struct Handler {
    callback_handler: CallbackHandler,
    cb_rx: mpsc::Receiver<InternalServerMsg>,
    connlib: Option<connlib_client_shared::Session>,
    dns_controller: DnsController,
    ipc_rx: ipc::ServerRead,
    ipc_tx: ipc::ServerWrite,
    last_connlib_start_instant: Option<Instant>,
    tun_device: tun_device_manager::TunDeviceManager,
}

enum Event {
    Callback(InternalServerMsg),
    Ipc(IpcClientMsg),
}

impl Handler {
    fn new(ipc_rx: ipc::ServerRead, ipc_tx: ipc::ServerWrite) -> Result<Self> {
        let (cb_tx, cb_rx) = mpsc::channel(10);
        let tun_device = tun_device_manager::TunDeviceManager::new()?;

        Ok(Self {
            callback_handler: CallbackHandler { cb_tx },
            cb_rx,
            connlib: None,
            dns_controller: Default::default(),
            ipc_rx,
            ipc_tx,
            last_connlib_start_instant: None,
            tun_device,
        })
    }

    // Infallible so that we only give up on an IPC client explicitly
    async fn run(&mut self) {
        loop {
            let event = {
                // This borrows `self` so we must drop it before handling the `Event`.
                let cb = pin!(self.cb_rx.recv());
                match future::select(self.ipc_rx.next(), cb).await {
                    future::Either::Left((Some(Ok(x)), _)) => Event::Ipc(x),
                    future::Either::Left((Some(Err(error)), _)) => {
                        tracing::error!(?error, "Error while deserializing IPC message");
                        continue;
                    }
                    future::Either::Left((None, _)) => {
                        tracing::info!("IPC client disconnected");
                        break;
                    }
                    future::Either::Right((Some(x), _)) => Event::Callback(x),
                    future::Either::Right((None, _)) => {
                        tracing::error!("Impossible - Callback channel closed");
                        break;
                    }
                }
            };
            match event {
                Event::Callback(x) => {
                    if let Err(error) = self.handle_connlib_cb(x).await {
                        tracing::error!(?error, "Error while handling connlib callback");
                        continue;
                    }
                }
                Event::Ipc(msg) => {
                    if let Err(error) = self.handle_ipc_msg(msg) {
                        tracing::error!(?error, "Error while handling IPC message from client");
                        continue;
                    }
                }
            }
        }
    }

    async fn handle_connlib_cb(&mut self, msg: InternalServerMsg) -> Result<()> {
        match msg {
            InternalServerMsg::Ipc(msg) => {
                // The first `OnUpdateResources` marks when connlib is fully initialized
                if let IpcServerMsg::OnUpdateResources(_) = &msg {
                    if let Some(instant) = self.last_connlib_start_instant.take() {
                        let dur = instant.elapsed();
                        tracing::info!(?dur, "Connlib started");
                    }
                }
                self.ipc_tx
                    .send(&msg)
                    .await
                    .context("Error while sending IPC message")?
            }
            InternalServerMsg::OnSetInterfaceConfig { ipv4, ipv6, dns } => {
                self.tun_device.set_ips(ipv4, ipv6).await?;
                self.dns_controller.set_dns(&dns).await?;
                self.ipc_tx
                    .send(&IpcServerMsg::OnTunnelReady)
                    .await
                    .context("Error while sending `OnTunnelReady`")?
            }
            InternalServerMsg::OnUpdateRoutes { ipv4, ipv6 } => {
                self.tun_device.set_routes(ipv4, ipv6).await?
            }
        }
        Ok(())
    }

    fn handle_ipc_msg(&mut self, msg: IpcClientMsg) -> Result<()> {
        match msg {
            IpcClientMsg::Connect { api_url, token } => {
                let token = secrecy::SecretString::from(token);
                assert!(self.connlib.is_none());
                let device_id =
                    device_id::get_or_create().context("Failed to get / create device ID")?;
                let (private_key, public_key) = keypair();

                let url = LoginUrl::client(
                    Url::parse(&api_url)?,
                    &token,
                    device_id.id,
                    None,
                    public_key.to_bytes(),
                )?;

                self.last_connlib_start_instant = Some(Instant::now());
                let args = ConnectArgs {
                    url,
                    sockets: Sockets::new(),
                    private_key,
                    os_version_override: None,
                    app_version: env!("CARGO_PKG_VERSION").to_string(),
                    callbacks: self.callback_handler.clone(),
                    max_partition_time: Some(Duration::from_secs(60 * 60 * 24 * 30)),
                };
                let new_session = Session::connect(args, tokio::runtime::Handle::try_current()?);
                new_session.set_dns(dns_control::system_resolvers().unwrap_or_default());
                self.connlib = Some(new_session);
            }
            IpcClientMsg::Disconnect => {
                if let Some(connlib) = self.connlib.take() {
                    connlib.disconnect();
                } else {
                    tracing::error!("Error - Got Disconnect when we're already not connected");
                }
            }
            IpcClientMsg::Reconnect => self
                .connlib
                .as_mut()
                .context("No connlib session")?
                .reconnect(),
            IpcClientMsg::SetDns(v) => self
                .connlib
                .as_mut()
                .context("No connlib session")?
                .set_dns(v),
        }
        Ok(())
    }
}

#[allow(dead_code)]
enum SignalKind {
    /// SIGHUP
    ///
    /// Not caught on Windows
    Hangup,
    /// SIGINT
    Interrupt,
}

/// Read the token from disk if it was not in the environment
///
/// # Returns
/// - `Ok(None)` if there is no token to be found
/// - `Ok(Some(_))` if we found the token
/// - `Err(_)` if we found the token on disk but failed to read it
fn get_token(
    token_env_var: Option<SecretString>,
    token_path: &Path,
) -> Result<Option<SecretString>> {
    // This is very simple but I don't want to write it twice
    if let Some(token) = token_env_var {
        return Ok(Some(token));
    }
    read_token_file(token_path)
}

/// Try to retrieve the token from disk
///
/// Sync because we do blocking file I/O
fn read_token_file(path: &Path) -> Result<Option<SecretString>> {
    if let Ok(token) = std::env::var(TOKEN_ENV_KEY) {
        std::env::remove_var(TOKEN_ENV_KEY);

        let token = SecretString::from(token);
        // Token was provided in env var
        tracing::info!(
            ?path,
            ?TOKEN_ENV_KEY,
            "Found token in env var, ignoring any token that may be on disk."
        );
        return Ok(Some(token));
    }

    if std::fs::metadata(path).is_err() {
        return Ok(None);
    }
    platform::check_token_permissions(path)?;

    let Ok(bytes) = std::fs::read(path) else {
        // We got the metadata a second ago, but can't read the file itself.
        // Pretty strange, would have to be a disk fault or TOCTOU.
        tracing::info!(?path, "Token file existed but now is unreadable");
        return Ok(None);
    };
    let token = String::from_utf8(bytes)?.trim().to_string();
    let token = SecretString::from(token);

    tracing::info!(?path, "Loaded token from disk");
    Ok(Some(token))
}

/// Reads the log filter for the IPC service
///
/// e.g. `info`
///
/// Reads from:
/// 1. `RUST_LOG` env var
/// 2. `known_dirs::ipc_log_filter()` file
/// 3. Hard-coded default `SERVICE_RUST_LOG`
///
/// Errors if something is badly wrong, e.g. the directory for the config file
/// can't be computed
fn get_log_filter() -> Result<String> {
    if let Ok(filter) = std::env::var(EnvFilter::DEFAULT_ENV) {
        return Ok(filter);
    }

    if let Ok(filter) = std::fs::read_to_string(
        known_dirs::ipc_log_filter()
            .context("Failed to compute directory for log filter config file")?,
    )
    .map(|s| s.trim().to_string())
    {
        return Ok(filter);
    }

    Ok(SERVICE_RUST_LOG.to_string())
}

/// Sets up logging for stdout only, with INFO level by default
pub fn setup_stdout_logging() -> Result<()> {
    let filter = EnvFilter::new(get_log_filter().context("Can't read log filter")?);
    let layer = fmt::layer().with_filter(filter);
    let subscriber = Registry::default().with(layer);
    set_global_default(subscriber)?;
    Ok(())
}

/// Starts logging for the production IPC service
///
/// Returns: A `Handle` that must be kept alive. Dropping it stops logging
/// and flushes the log file.
fn setup_ipc_service_logging(
    log_dir: Option<PathBuf>,
) -> Result<connlib_client_shared::file_logger::Handle> {
    // If `log_dir` is Some, use that. Else call `ipc_service_logs`
    let log_dir = log_dir.map_or_else(
        || known_dirs::ipc_service_logs().context("Should be able to compute IPC service logs dir"),
        Ok,
    )?;
    std::fs::create_dir_all(&log_dir)
        .context("We should have permissions to create our log dir")?;
    let (layer, handle) = file_logger::layer(&log_dir);
    let log_filter = get_log_filter().context("Couldn't read log filter")?;
    let filter = EnvFilter::new(&log_filter);
    let subscriber = Registry::default().with(layer.with_filter(filter));
    set_global_default(subscriber).context("`set_global_default` should always work)")?;
    tracing::info!(git_version = GIT_VERSION, ?log_filter);
    Ok(handle)
}

#[cfg(test)]
mod tests {
    use super::{Cli, CliIpcService, CmdIpc};
    use clap::Parser;
    use std::path::PathBuf;
    use url::Url;

    // Can't remember how Clap works sometimes
    // Also these are examples
    #[test]
    fn cli() -> anyhow::Result<()> {
        let exe_name = "firezone-headless-client";

        let actual = Cli::parse_from([exe_name, "--api-url", "wss://api.firez.one"]);
        assert_eq!(actual.api_url, Url::parse("wss://api.firez.one")?);
        assert!(!actual.check);

        let actual = Cli::parse_from([exe_name, "--check", "--log-dir", "bogus_log_dir"]);
        assert!(actual.check);
        assert_eq!(actual.common.log_dir, Some(PathBuf::from("bogus_log_dir")));

        let actual =
            CliIpcService::parse_from([exe_name, "--log-dir", "bogus_log_dir", "run-debug"]);
        assert_eq!(actual.command, CmdIpc::RunDebug);
        assert_eq!(actual.common.log_dir, Some(PathBuf::from("bogus_log_dir")));

        let actual = CliIpcService::parse_from([exe_name, "run"]);
        assert_eq!(actual.command, CmdIpc::Run);

        Ok(())
    }
}
