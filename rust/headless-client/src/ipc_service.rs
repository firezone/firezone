use crate::{
    device_id,
    dns_control::{self, DnsController},
    known_dirs, CallbackHandler, CliCommon, InternalServerMsg, IpcServerMsg, SignalKind, Signals,
    TOKEN_ENV_KEY,
};
use anyhow::{bail, Context as _, Result};
use clap::Parser;
use connlib_client_shared::{file_logger, keypair, ConnectArgs, LoginUrl, Session, Sockets};
use connlib_shared::tun_device_manager;
use futures::{future, SinkExt as _, StreamExt as _};
use std::{net::IpAddr, path::PathBuf, pin::pin, time::Duration};
use tokio::{sync::mpsc, time::Instant};
use tracing::subscriber::set_global_default;
use tracing_subscriber::{layer::SubscriberExt, EnvFilter, Layer, Registry};
use url::Url;

pub mod ipc;
use ipc::{Server as IpcServer, ServiceId};

#[cfg(target_os = "linux")]
#[path = "ipc_service/linux.rs"]
pub mod platform;

#[cfg(target_os = "windows")]
#[path = "ipc_service/windows.rs"]
pub mod platform;

/// Default log filter for the IPC service
#[cfg(debug_assertions)]
const SERVICE_RUST_LOG: &str = "firezone_headless_client=debug,firezone_tunnel=debug,phoenix_channel=debug,connlib_shared=debug,connlib_client_shared=debug,boringtun=debug,snownet=debug,str0m=info,info";

/// Default log filter for the IPC service
#[cfg(not(debug_assertions))]
const SERVICE_RUST_LOG: &str = "str0m=warn,info";

#[derive(clap::Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Cmd,

    #[command(flatten)]
    common: CliCommon,
}

#[derive(clap::Subcommand)]
enum Cmd {
    /// Needed to test the IPC service on aarch64 Windows,
    /// where the Tauri MSI bundler doesn't work yet
    Install,
    Run,
    RunDebug,
}

impl Default for Cmd {
    fn default() -> Self {
        Self::Run
    }
}

#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub enum ClientMsg {
    Connect { api_url: String, token: String },
    Disconnect,
    Reconnect,
    SetDns(Vec<IpAddr>),
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
    let cli = Cli::try_parse()?;
    match cli.command {
        Cmd::Install => platform::install_ipc_service(),
        Cmd::Run => platform::run_ipc_service(cli.common),
        Cmd::RunDebug => run_debug_ipc_service(),
    }
}

fn run_debug_ipc_service() -> Result<()> {
    crate::setup_stdout_logging()?;
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
    Ipc(ClientMsg),
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

    fn handle_ipc_msg(&mut self, msg: ClientMsg) -> Result<()> {
        match msg {
            ClientMsg::Connect { api_url, token } => {
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
            ClientMsg::Disconnect => {
                if let Some(connlib) = self.connlib.take() {
                    connlib.disconnect();
                } else {
                    tracing::error!("Error - Got Disconnect when we're already not connected");
                }
            }
            ClientMsg::Reconnect => self
                .connlib
                .as_mut()
                .context("No connlib session")?
                .reconnect(),
            ClientMsg::SetDns(v) => self
                .connlib
                .as_mut()
                .context("No connlib session")?
                .set_dns(v),
        }
        Ok(())
    }
}

/// Starts logging for the production IPC service
///
/// Returns: A `Handle` that must be kept alive. Dropping it stops logging
/// and flushes the log file.
fn setup_logging(log_dir: Option<PathBuf>) -> Result<connlib_client_shared::file_logger::Handle> {
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
    tracing::info!(git_version = crate::GIT_VERSION, ?log_filter);
    Ok(handle)
}

/// Reads the log filter for the IPC service or for debug commands
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
pub(crate) fn get_log_filter() -> Result<String> {
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

#[cfg(test)]
mod tests {
    use super::{Cli, Cmd};
    use clap::Parser;
    use std::path::PathBuf;

    // Can't remember how Clap works sometimes
    // Also these are examples
    #[test]
    fn cli() {
        let exe_name = "firezone-client-ipc";

        let actual = Cli::parse_from([exe_name, "--log-dir", "bogus_log_dir", "run-debug"]);
        assert!(matches!(actual.command, Cmd::RunDebug));
        assert_eq!(actual.common.log_dir, Some(PathBuf::from("bogus_log_dir")));

        let actual = Cli::parse_from([exe_name, "run"]);
        assert!(matches!(actual.command, Cmd::Run));
    }
}
