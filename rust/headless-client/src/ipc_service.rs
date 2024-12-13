use crate::{
    device_id, dns_control::DnsController, known_dirs, signals, CallbackHandler, CliCommon,
    ConnlibMsg, LogFilterReloader,
};
use anyhow::{bail, Context as _, Result};
use atomicwrites::{AtomicFile, OverwriteBehavior};
use clap::Parser;
use connlib_model::ResourceView;
use firezone_bin_shared::{
    platform::{tcp_socket_factory, udp_socket_factory, DnsControlMethod},
    TunDeviceManager, TOKEN_ENV_KEY,
};
use firezone_logging::{anyhow_dyn_err, sentry_layer, std_dyn_err, telemetry_span};
use firezone_telemetry::Telemetry;
use futures::{
    future::poll_fn,
    task::{Context, Poll},
    Future as _, SinkExt as _, Stream as _,
};
use phoenix_channel::LoginUrl;
use secrecy::SecretString;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeSet,
    io::{self, Write},
    net::IpAddr,
    path::PathBuf,
    pin::pin,
    sync::Arc,
    time::Duration,
};
use tokio::{sync::mpsc, time::Instant};
use tracing_subscriber::{layer::SubscriberExt, reload, EnvFilter, Layer, Registry};
use url::Url;

pub mod ipc;
use backoff::ExponentialBackoffBuilder;
use connlib_model::ResourceId;
use ipc::{Server as IpcServer, ServiceId};
use phoenix_channel::{get_user_agent, PhoenixChannel};
use secrecy::Secret;

#[cfg(target_os = "linux")]
#[path = "ipc_service/linux.rs"]
pub mod platform;

#[cfg(target_os = "windows")]
#[path = "ipc_service/windows.rs"]
pub mod platform;

/// Default log filter for the IPC service
#[cfg(debug_assertions)]
const SERVICE_RUST_LOG: &str = "debug";

/// Default log filter for the IPC service
#[cfg(not(debug_assertions))]
const SERVICE_RUST_LOG: &str = "info";

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

#[derive(Debug, PartialEq, Deserialize, Serialize)]
pub enum ClientMsg {
    ClearLogs,
    Connect {
        api_url: String,
        token: String,
    },
    Disconnect,
    ApplyLogFilter {
        directives: String,
    },
    Reset,
    SetDns(Vec<IpAddr>),
    SetDisabledResources(BTreeSet<ResourceId>),
    StartTelemetry {
        environment: String,
        release: String,
        account_slug: Option<String>,
    },
    StopTelemetry,
}

/// Messages that end up in the GUI, either forwarded from connlib or from the IPC service.
#[derive(Debug, Deserialize, Serialize)]
pub enum ServerMsg {
    /// The IPC service finished clearing its log dir.
    ClearedLogs(Result<(), String>),
    ConnectResult(Result<(), Error>),
    DisconnectedGracefully,
    OnDisconnect {
        error_msg: String,
        is_authentication_error: bool,
    },
    OnUpdateResources(Vec<ResourceView>),
    /// The IPC service is terminating, maybe due to a software update
    ///
    /// This is a hint that the Client should exit with a message like,
    /// "Firezone is updating, please restart the GUI" instead of an error like,
    /// "IPC connection closed".
    TerminatingGracefully,
    /// The interface and tunnel are ready for traffic.
    TunnelReady,
}

// All variants are `String` because almost no error type implements `Serialize`
#[derive(Debug, Deserialize, Serialize, thiserror::Error)]
pub enum Error {
    #[error("IO error: {0}")]
    Io(String),
    #[error("{0}")]
    Other(String),
}

impl From<io::Error> for Error {
    fn from(v: io::Error) -> Self {
        Self::Io(v.to_string())
    }
}

impl From<anyhow::Error> for Error {
    fn from(v: anyhow::Error) -> Self {
        Self::Other(format!("{v:#}"))
    }
}

/// Only called from the GUI Client's build of the IPC service
pub fn run_only_ipc_service() -> Result<()> {
    // Docs indicate that `remove_var` should actually be marked unsafe
    // SAFETY: We haven't spawned any other threads, this code should be the first
    // thing to run after entering `main` and parsing CLI args.
    // So nobody else is reading the environment.
    unsafe {
        // This removes the token from the environment per <https://security.stackexchange.com/a/271285>. We run as root so it may not do anything besides defense-in-depth.
        std::env::remove_var(TOKEN_ENV_KEY);
    }
    assert!(std::env::var(TOKEN_ENV_KEY).is_err());
    let cli = Cli::try_parse()?;
    match cli.command {
        Cmd::Install => platform::install_ipc_service(),
        Cmd::Run => platform::run_ipc_service(cli.common),
        Cmd::RunDebug => run_debug_ipc_service(cli),
        Cmd::RunSmokeTest => run_smoke_test(),
    }
}

fn run_debug_ipc_service(cli: Cli) -> Result<()> {
    let log_filter_reloader = crate::setup_stdout_logging()?;
    tracing::info!(
        arch = std::env::consts::ARCH,
        // version = env!("CARGO_PKG_VERSION"), TODO: Fix once `ipc_service` is moved to `gui-client`.
        system_uptime_seconds = crate::uptime::get().map(|dur| dur.as_secs()),
    );
    if !platform::elevation_check()? {
        bail!("IPC service failed its elevation check, try running as admin / root");
    }
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let _guard = rt.enter();
    let mut signals = signals::Terminate::new()?;

    rt.block_on(ipc_listen(
        cli.common.dns_control,
        &log_filter_reloader,
        &mut signals,
    ))
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
    let log_filter_reloader = crate::setup_stdout_logging()?;
    if !platform::elevation_check()? {
        bail!("IPC service failed its elevation check, try running as admin / root");
    }
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let _guard = rt.enter();
    let mut dns_controller = DnsController {
        dns_control_method: Default::default(),
    };
    // Deactivate Firezone DNS control in case the system or IPC service crashed
    // and we need to recover. <https://github.com/firezone/firezone/issues/4899>
    dns_controller.deactivate()?;
    let mut signals = signals::Terminate::new()?;
    let mut telemetry = Telemetry::default();

    // Couldn't get the loop to work here yet, so SIGHUP is not implemented
    rt.block_on(async {
        device_id::get_or_create().context("Failed to read / create device ID")?;
        let mut server = IpcServer::new(ServiceId::Prod).await?;
        let _ = Handler::new(
            &mut server,
            &mut dns_controller,
            &log_filter_reloader,
            &mut telemetry,
        )
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
async fn ipc_listen(
    dns_control_method: DnsControlMethod,
    log_filter_reloader: &LogFilterReloader,
    signals: &mut signals::Terminate,
) -> Result<()> {
    // Create the device ID and IPC service config dir if needed
    // This also gives the GUI a safe place to put the log filter config
    let firezone_id = device_id::get_or_create()
        .context("Failed to read / create device ID")?
        .id;

    let mut telemetry = Telemetry::default();
    telemetry.set_firezone_id(firezone_id);

    let mut server = IpcServer::new(ServiceId::Prod).await?;
    let mut dns_controller = DnsController { dns_control_method };
    loop {
        let mut handler_fut = pin!(Handler::new(
            &mut server,
            &mut dns_controller,
            log_filter_reloader,
            &mut telemetry,
        ));
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
    dns_controller: &'a mut DnsController,
    ipc_rx: ipc::ServerRead,
    ipc_tx: ipc::ServerWrite,
    last_connlib_start_instant: Option<Instant>,
    log_filter_reloader: &'a LogFilterReloader,
    session: Option<Session>,
    telemetry: &'a mut Telemetry, // Handle to the sentry.io telemetry module
    tun_device: TunDeviceManager,
}

struct Session {
    cb_rx: mpsc::Receiver<ConnlibMsg>,
    connlib: connlib_client_shared::Session,
}

enum Event {
    Callback(ConnlibMsg),
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
    async fn new(
        server: &mut IpcServer,
        dns_controller: &'a mut DnsController,
        log_filter_reloader: &'a LogFilterReloader,
        telemetry: &'a mut Telemetry,
    ) -> Result<Self> {
        dns_controller.deactivate()?;
        let (ipc_rx, ipc_tx) = server
            .next_client_split()
            .await
            .context("Failed to wait for incoming IPC connection from a GUI")?;
        let tun_device = TunDeviceManager::new(ip_packet::PACKET_SIZE, crate::NUM_TUN_THREADS)?;

        Ok(Self {
            dns_controller,
            ipc_rx,
            ipc_tx,
            last_connlib_start_instant: None,
            log_filter_reloader,
            session: None,
            telemetry,
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
                        tracing::error!(
                            error = anyhow_dyn_err(&error),
                            "Error while handling connlib callback"
                        );
                        continue;
                    }
                }
                Event::CallbackChannelClosed => {
                    tracing::error!("Impossible - Callback channel closed");
                    break HandlerOk::Err;
                }
                Event::Ipc(msg) => {
                    let msg_variant = serde_variant::to_variant_name(&msg)
                        .expect("IPC messages should be enums, not structs or anything else.");
                    let _entered =
                        tracing::error_span!("handle_ipc_msg", msg = %msg_variant).entered();
                    if let Err(error) = self.handle_ipc_msg(msg).await {
                        tracing::error!(
                            error = anyhow_dyn_err(&error),
                            "Error while handling IPC message from client"
                        );
                        continue;
                    }
                }
                Event::IpcDisconnected => {
                    tracing::info!("IPC client disconnected");
                    break HandlerOk::ClientDisconnected;
                }
                Event::IpcError(error) => {
                    tracing::error!(
                        error = anyhow_dyn_err(&error),
                        "Error while deserializing IPC message"
                    );
                    continue;
                }
                Event::Terminate => {
                    tracing::info!(
                        "Caught SIGINT / SIGTERM / Ctrl+C while an IPC client is connected"
                    );
                    // Ignore the result here because we're terminating anyway.
                    let _ = self.ipc_tx.send(&ServerMsg::TerminatingGracefully).await;
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
            return Poll::Ready(match result {
                Some(Ok(x)) => Event::Ipc(x),
                Some(Err(error)) => Event::IpcError(error),
                None => Event::IpcDisconnected,
            });
        }
        if let Some(session) = self.session.as_mut() {
            // `tokio::sync::mpsc::Receiver::recv` is cancel-safe.
            if let Poll::Ready(option) = session.cb_rx.poll_recv(cx) {
                return Poll::Ready(match option {
                    Some(x) => Event::Callback(x),
                    None => Event::CallbackChannelClosed,
                });
            }
        }
        Poll::Pending
    }

    async fn handle_connlib_cb(&mut self, msg: ConnlibMsg) -> Result<()> {
        match msg {
            ConnlibMsg::OnDisconnect {
                error_msg,
                is_authentication_error,
            } => {
                if let Some(session) = self.session.take() {
                    // Identical to dropping, but looks nicer
                    session.connlib.disconnect();
                }
                self.dns_controller.deactivate()?;
                self.ipc_tx
                    .send(&ServerMsg::OnDisconnect {
                        error_msg,
                        is_authentication_error,
                    })
                    .await
                    .context("Error while sending IPC message `OnDisconnect`")?
            }
            ConnlibMsg::OnSetInterfaceConfig { ipv4, ipv6, dns } => {
                self.tun_device.set_ips(ipv4, ipv6).await?;
                self.dns_controller.set_dns(dns).await?;
                if let Some(instant) = self.last_connlib_start_instant.take() {
                    tracing::info!(elapsed = ?instant.elapsed(), "Tunnel ready");
                }
                self.ipc_tx
                    .send(&ServerMsg::TunnelReady)
                    .await
                    .context("Error while sending IPC message `TunnelReady`")?;
            }
            ConnlibMsg::OnUpdateResources(resources) => {
                // On every resources update, flush DNS to mitigate <https://github.com/firezone/firezone/issues/5052>
                self.dns_controller.flush()?;
                self.ipc_tx
                    .send(&ServerMsg::OnUpdateResources(resources))
                    .await
                    .context("Error while sending IPC message `OnUpdateResources`")?;
            }
            ConnlibMsg::OnUpdateRoutes { ipv4, ipv6 } => {
                self.tun_device.set_routes(ipv4, ipv6).await?;
                self.dns_controller.flush()?;
            }
        }
        Ok(())
    }

    async fn handle_ipc_msg(&mut self, msg: ClientMsg) -> Result<()> {
        match msg {
            ClientMsg::ClearLogs => {
                let result = crate::clear_logs(
                    &crate::known_dirs::ipc_service_logs().context("Can't compute logs dir")?,
                )
                .await;
                self.ipc_tx
                    .send(&ServerMsg::ClearedLogs(result.map_err(|e| e.to_string())))
                    .await
                    .context("Error while sending IPC message")?
            }
            ClientMsg::Connect { api_url, token } => {
                // Warning: Connection errors don't bubble to callers of `handle_ipc_msg`.
                let token = secrecy::SecretString::from(token);
                let result = self.connect_to_firezone(&api_url, token);

                self.ipc_tx
                    .send(&ServerMsg::ConnectResult(result))
                    .await
                    .context("Failed to send `ConnectResult`")?
            }
            ClientMsg::Disconnect => {
                if let Some(session) = self.session.take() {
                    // Identical to dropping it, but looks nicer.
                    session.connlib.disconnect();
                    self.dns_controller.deactivate()?;
                }
                // Always send `DisconnectedGracefully` even if we weren't connected,
                // so this will be idempotent.
                self.ipc_tx
                    .send(&ServerMsg::DisconnectedGracefully)
                    .await
                    .context("Failed to send `DisconnectedGracefully`")?;
            }
            ClientMsg::ApplyLogFilter { directives } => {
                self.log_filter_reloader.reload(directives.clone())?;

                let path = known_dirs::ipc_log_filter()?;

                if let Err(e) = AtomicFile::new(&path, OverwriteBehavior::AllowOverwrite)
                    .write(|f| f.write_all(directives.as_bytes()))
                {
                    tracing::warn!(path = %path.display(), %directives, error = std_dyn_err(&e), "Failed to write new log directives");
                }
            }
            ClientMsg::Reset => {
                if self.last_connlib_start_instant.is_some() {
                    tracing::debug!("Ignoring reset since we're still signing in");
                    return Ok(());
                }
                let Some(session) = self.session.as_ref() else {
                    tracing::debug!("Cannot reset if we're signed out");
                    return Ok(());
                };

                session.connlib.reset();
            }
            ClientMsg::SetDns(resolvers) => {
                let Some(session) = self.session.as_ref() else {
                    tracing::debug!("Cannot set DNS resolvers if we're signed out");
                    return Ok(());
                };

                tracing::debug!(?resolvers);
                session.connlib.set_dns(resolvers);
            }
            ClientMsg::SetDisabledResources(disabled_resources) => {
                let Some(session) = self.session.as_ref() else {
                    // At this point, the GUI has already saved the disabled Resources to disk, so it'll be correct on the next sign-in anyway.
                    tracing::debug!("Cannot set disabled resources if we're signed out");
                    return Ok(());
                };

                session.connlib.set_disabled_resources(disabled_resources);
            }
            ClientMsg::StartTelemetry {
                environment,
                release,
                account_slug,
            } => {
                self.telemetry
                    .start(&environment, &release, firezone_telemetry::IPC_SERVICE_DSN);

                if let Some(account_slug) = account_slug {
                    self.telemetry.set_account_slug(account_slug);
                }
            }
            ClientMsg::StopTelemetry => {
                self.telemetry.stop().await;
            }
        }
        Ok(())
    }

    /// Connects connlib
    ///
    /// Panics if there's no Tokio runtime or if connlib is already connected
    ///
    /// Throws matchable errors for bad URLs, unable to reach the portal, or unable to create the tunnel device
    fn connect_to_firezone(&mut self, api_url: &str, token: SecretString) -> Result<(), Error> {
        let _connect_span = telemetry_span!("connect_to_firezone").entered();

        assert!(self.session.is_none());
        let device_id = device_id::get_or_create().context("Failed to get-or-create device ID")?;
        self.telemetry.set_firezone_id(device_id.id.clone());

        let url = LoginUrl::client(
            Url::parse(api_url).context("Failed to parse URL")?,
            &token,
            device_id.id,
            None,
            device_id::device_info(),
        )
        .context("Failed to create `LoginUrl`")?;

        self.last_connlib_start_instant = Some(Instant::now());
        let (cb_tx, cb_rx) = mpsc::channel(1_000);
        let callbacks = CallbackHandler { cb_tx };

        // Synchronous DNS resolution here
        let portal = PhoenixChannel::disconnected(
            Secret::new(url),
            // The IPC service must use the GUI's version number, not the Headless Client's.
            // But refactoring to separate the IPC service from the Headless Client will take a while.
            // mark:next-gui-version
            get_user_agent(None, "1.4.1"),
            "client",
            (),
            || {
                ExponentialBackoffBuilder::default()
                    .with_max_elapsed_time(Some(Duration::from_secs(60 * 60 * 24 * 30)))
                    .build()
            },
            Arc::new(tcp_socket_factory),
        )?; // Turn this `io::Error` directly into an `Error` so we can distinguish it from others in the GUI client.

        // Read the resolvers before starting connlib, in case connlib's startup interferes.
        let dns = self.dns_controller.system_resolvers();
        let connlib = connlib_client_shared::Session::connect(
            Arc::new(tcp_socket_factory),
            Arc::new(udp_socket_factory),
            callbacks,
            portal,
            tokio::runtime::Handle::current(),
        );
        // Call `set_dns` before `set_tun` so that the tunnel starts up with a valid list of resolvers.
        tracing::debug!(?dns, "Calling `set_dns`...");
        connlib.set_dns(dns);

        let tun = {
            let _guard = telemetry_span!("create_tun_device").entered();

            self.tun_device
                .make_tun()
                .context("Failed to create TUN device")?
        };
        connlib.set_tun(Box::new(tun));

        let session = Session { cb_rx, connlib };
        self.session = Some(session);

        Ok(())
    }
}

/// Starts logging for the production IPC service
///
/// Returns: A `Handle` that must be kept alive. Dropping it stops logging
/// and flushes the log file.
fn setup_logging(
    log_dir: Option<PathBuf>,
) -> Result<(firezone_logging::file::Handle, LogFilterReloader)> {
    // If `log_dir` is Some, use that. Else call `ipc_service_logs`
    let log_dir = log_dir.map_or_else(
        || known_dirs::ipc_service_logs().context("Should be able to compute IPC service logs dir"),
        Ok,
    )?;
    std::fs::create_dir_all(&log_dir)
        .context("We should have permissions to create our log dir")?;

    let (layer, handle) = firezone_logging::file::layer(&log_dir);

    let directives = get_log_filter().context("Couldn't read log filter")?;
    let (filter, reloader) = reload::Layer::new(firezone_logging::try_filter(&directives)?);

    let subscriber = Registry::default()
        .with(layer.with_filter(filter))
        .with(sentry_layer());
    firezone_logging::init(subscriber)?;

    tracing::info!(
        arch = std::env::consts::ARCH,
        // version = env!("CARGO_PKG_VERSION"), TODO: Fix once `ipc_service` is moved to `gui-client`.
        system_uptime_seconds = crate::uptime::get().map(|dur| dur.as_secs()),
        %directives
    );

    Ok((handle, reloader))
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

    if let Ok(filter) =
        std::fs::read_to_string(known_dirs::ipc_log_filter()?).map(|s| s.trim().to_string())
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

    const EXE_NAME: &str = "firezone-client-ipc";

    // Can't remember how Clap works sometimes
    // Also these are examples
    #[test]
    fn cli() {
        let actual =
            Cli::try_parse_from([EXE_NAME, "--log-dir", "bogus_log_dir", "run-debug"]).unwrap();
        assert!(matches!(actual.command, Cmd::RunDebug));
        assert_eq!(actual.common.log_dir, Some(PathBuf::from("bogus_log_dir")));

        let actual = Cli::try_parse_from([EXE_NAME, "run"]).unwrap();
        assert!(matches!(actual.command, Cmd::Run));
    }
}
