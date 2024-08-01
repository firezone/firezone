use crate::{
    device_id,
    dns_control::{self, DnsController},
    known_dirs, signals, CallbackHandler, CliCommon, InternalServerMsg, IpcServerMsg,
    TOKEN_ENV_KEY,
};
use anyhow::{Context as _, Result};
use clap::Parser;
use connlib_client_shared::{file_logger, keypair, ConnectArgs, LoginUrl, Session};
use futures::{
    future::poll_fn,
    task::{Context, Poll},
    Future as _, SinkExt as _, Stream as _,
};
use std::{net::IpAddr, path::PathBuf, pin::pin, sync::Arc, time::Duration};
use tokio::{sync::mpsc, time::Instant};
use tracing::subscriber::set_global_default;
use tracing_subscriber::{layer::SubscriberExt, EnvFilter, Layer, Registry};
use url::Url;

pub mod ipc;
use firezone_bin_shared::TunDeviceManager;
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
    RunSmokeTest,
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
        Cmd::RunSmokeTest => run_smoke_test(),
    }
}

fn run_debug_ipc_service() -> Result<()> {
    crate::setup_stdout_logging()?;
    tracing::info!(
        arch = std::env::consts::ARCH,
        git_version = crate::GIT_VERSION,
        system_uptime_seconds = crate::uptime::get().map(|dur| dur.as_secs()),
    );
    let rt = tokio::runtime::Runtime::new()?;
    let _guard = rt.enter();
    let mut signals = signals::Terminate::new()?;

    rt.block_on(ipc_listen(&mut signals))
}

#[cfg(not(debug_assertions))]
fn run_smoke_test() -> Result<()> {
    anyhow::bail!("Smoke test is not built for release binaries.");
}

/// Listen for exactly one connection from a GUI, then exit
///
/// This makes the timing neater in case the GUI starts up slowly.
#[cfg(debug_assertions)]
fn run_smoke_test() -> Result<()> {
    crate::setup_stdout_logging()?;
    let rt = tokio::runtime::Runtime::new()?;
    let _guard = rt.enter();
    let mut dns_controller = DnsController::default();
    // Deactivate Firezone DNS control in case the system or IPC service crashed
    // and we need to recover. <https://github.com/firezone/firezone/issues/4899>
    dns_controller.deactivate()?;
    let mut signals = signals::Terminate::new()?;

    // Couldn't get the loop to work here yet, so SIGHUP is not implemented
    rt.block_on(async {
        device_id::get_or_create().context("Failed to read / create device ID")?;
        let mut server = IpcServer::new(ServiceId::Prod).await?;
        let _ = Handler::new(&mut server, &mut dns_controller)
            .await?
            .run(&mut signals)
            .await;
        Ok::<_, anyhow::Error>(())
    })
}

/// Run the IPC service and terminate gracefully if we catch a terminate signal
///
/// If an IPC client is connected when we catch a terminate signal, we send the
/// client a hint about that before we exit.
async fn ipc_listen(signals: &mut signals::Terminate) -> Result<()> {
    // Create the device ID and IPC service config dir if needed
    // This also gives the GUI a safe place to put the log filter config
    device_id::get_or_create().context("Failed to read / create device ID")?;
    let mut server = IpcServer::new(ServiceId::Prod).await?;
    let mut dns_controller = DnsController::default();
    loop {
        let mut handler_fut = pin!(Handler::new(&mut server, &mut dns_controller));
        let Some(handler) = poll_fn(|cx| {
            if let Poll::Ready(()) = signals.poll_recv(cx) {
                Poll::Ready(None)
            } else if let Poll::Ready(handler) = handler_fut.as_mut().poll(cx) {
                Poll::Ready(Some(handler))
            } else {
                Poll::Pending
            }
        })
        .await
        else {
            tracing::info!("Caught SIGINT / SIGTERM / Ctrl+C while waiting on the next client.");
            break;
        };
        let mut handler = handler?;
        if let HandlerOk::ServiceTerminating = handler.run(signals).await {
            break;
        }
    }
    Ok(())
}

/// Handles one IPC client
struct Handler<'a> {
    callback_handler: CallbackHandler,
    cb_rx: mpsc::Receiver<InternalServerMsg>,
    connlib: Option<connlib_client_shared::Session>,
    dns_controller: &'a mut DnsController,
    ipc_rx: ipc::ServerRead,
    ipc_tx: ipc::ServerWrite,
    last_connlib_start_instant: Option<Instant>,
    tun_device: TunDeviceManager,
}

enum Event {
    Callback(InternalServerMsg),
    CallbackChannelClosed,
    Ipc(ClientMsg),
    IpcDisconnected,
    IpcError(anyhow::Error),
    Terminate,
}

// Open to better names
#[must_use]
enum HandlerOk {
    ClientDisconnected,
    Err,
    ServiceTerminating,
}

impl<'a> Handler<'a> {
    async fn new(server: &mut IpcServer, dns_controller: &'a mut DnsController) -> Result<Self> {
        dns_controller.deactivate()?;
        let (ipc_rx, ipc_tx) = server
            .next_client_split()
            .await
            .context("Failed to wait for incoming IPC connection from a GUI")?;
        let (cb_tx, cb_rx) = mpsc::channel(10);
        let tun_device = TunDeviceManager::new()?;

        Ok(Self {
            callback_handler: CallbackHandler { cb_tx },
            cb_rx,
            connlib: None,
            dns_controller,
            ipc_rx,
            ipc_tx,
            last_connlib_start_instant: None,
            tun_device,
        })
    }

    /// Run the event loop to communicate with an IPC client.
    ///
    /// If the IPC service needs to terminate, we catch that from `signals` and send
    /// the client a hint to shut itself down gracefully.
    ///
    /// The return type is infallible so that we only give up on an IPC client explicitly
    async fn run(&mut self, signals: &mut signals::Terminate) -> HandlerOk {
        loop {
            match poll_fn(|cx| self.next_event(cx, signals)).await {
                Event::Callback(x) => {
                    if let Err(error) = self.handle_connlib_cb(x).await {
                        tracing::error!(?error, "Error while handling connlib callback");
                        continue;
                    }
                }
                Event::CallbackChannelClosed => {
                    tracing::error!("Impossible - Callback channel closed");
                    break HandlerOk::Err;
                }
                Event::Ipc(msg) => {
                    if let Err(error) = self.handle_ipc_msg(msg) {
                        tracing::error!(?error, "Error while handling IPC message from client");
                        continue;
                    }
                }
                Event::IpcDisconnected => {
                    tracing::info!("IPC client disconnected");
                    break HandlerOk::ClientDisconnected;
                }
                Event::IpcError(error) => {
                    tracing::error!(?error, "Error while deserializing IPC message");
                    continue;
                }
                Event::Terminate => {
                    tracing::info!(
                        "Caught SIGINT / SIGTERM / Ctrl+C while an IPC client is connected"
                    );
                    self.ipc_tx
                        .send(&IpcServerMsg::TerminatingGracefully)
                        .await
                        .unwrap();
                    break HandlerOk::ServiceTerminating;
                }
            }
        }
    }

    fn next_event(
        &mut self,
        cx: &mut Context<'_>,
        signals: &mut signals::Terminate,
    ) -> Poll<Event> {
        // `recv` on signals is cancel-safe.
        if let Poll::Ready(()) = signals.poll_recv(cx) {
            return Poll::Ready(Event::Terminate);
        }
        // `FramedRead::next` is cancel-safe.
        if let Poll::Ready(result) = pin!(&mut self.ipc_rx).poll_next(cx) {
            return match result {
                Some(Ok(x)) => Poll::Ready(Event::Ipc(x)),
                Some(Err(error)) => Poll::Ready(Event::IpcError(error)),
                None => Poll::Ready(Event::IpcDisconnected),
            };
        }
        // `tokio::sync::mpsc::Receiver::recv` is cancel-safe.
        if let Poll::Ready(option) = self.cb_rx.poll_recv(cx) {
            return match option {
                Some(x) => Poll::Ready(Event::Callback(x)),
                None => Poll::Ready(Event::CallbackChannelClosed),
            };
        }
        Poll::Pending
    }

    async fn handle_connlib_cb(&mut self, msg: InternalServerMsg) -> Result<()> {
        match msg {
            InternalServerMsg::Ipc(msg) => {
                // The first `OnUpdateResources` marks when connlib is fully initialized
                if let IpcServerMsg::OnUpdateResources(_) = &msg {
                    if let Some(instant) = self.last_connlib_start_instant.take() {
                        tracing::info!(elapsed = ?instant.elapsed(), "Tunnel ready");
                    }

                    // On every resources update, flush DNS to mitigate <https://github.com/firezone/firezone/issues/5052>
                    self.dns_controller.flush().context("Failed to flush DNS")?;
                }
                self.ipc_tx
                    .send(&msg)
                    .await
                    .context("Error while sending IPC message")?
            }
            InternalServerMsg::OnSetInterfaceConfig { ipv4, ipv6, dns } => {
                self.tun_device
                    .set_ips(ipv4, ipv6)
                    .await
                    .context("Failed to set IPs")?;
                self.dns_controller
                    .set_dns(&dns)
                    .await
                    .context("Failed to control DNS")?;
            }
            InternalServerMsg::OnUpdateRoutes { ipv4, ipv6 } => self
                .tun_device
                .set_routes(ipv4, ipv6)
                .await
                .context("Failed to set routes")?,
        }
        Ok(())
    }

    fn handle_ipc_msg(&mut self, msg: ClientMsg) -> Result<()> {
        match msg {
            ClientMsg::Connect { api_url, token } => {
                let token = secrecy::SecretString::from(token);
                // There isn't an airtight way to implement a "disconnect and reconnect"
                // right now because `Session::disconnect` is fire-and-forget:
                // <https://github.com/firezone/firezone/blob/663367b6055ced7432866a40a60f9525db13288b/rust/connlib/clients/shared/src/lib.rs#L98-L103>
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
                    tcp_socket_factory: Arc::new(crate::tcp_socket_factory),
                    udp_socket_factory: Arc::new(crate::udp_socket_factory),
                    private_key,
                    os_version_override: None,
                    app_version: env!("CARGO_PKG_VERSION").to_string(),
                    callbacks: self.callback_handler.clone(),
                    max_partition_time: Some(Duration::from_secs(60 * 60 * 24 * 30)),
                };
                let new_session = Session::connect(args, tokio::runtime::Handle::try_current()?);
                new_session.set_tun(self.tun_device.make_tun()?);
                new_session.set_dns(dns_control::system_resolvers().unwrap_or_default());
                self.connlib = Some(new_session);
            }
            ClientMsg::Disconnect => {
                if let Some(connlib) = self.connlib.take() {
                    connlib.disconnect();
                    self.dns_controller.deactivate()?;
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
    let directives = get_log_filter().context("Couldn't read log filter")?;
    let filter = EnvFilter::new(&directives);
    let subscriber = Registry::default().with(layer.with_filter(filter));
    set_global_default(subscriber).context("`set_global_default` should always work)")?;
    tracing::info!(
        arch = std::env::consts::ARCH,
        git_version = crate::GIT_VERSION,
        os = std::env::consts::OS,
        system_uptime_seconds = crate::uptime::get().map(|dur| dur.as_secs()),
        ?directives
    );
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
