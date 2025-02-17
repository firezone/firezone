use crate::{
    ipc::{self, SocketId},
    logging,
};
use anyhow::{Context as _, Result, bail};
use atomicwrites::{AtomicFile, OverwriteBehavior};
use backoff::ExponentialBackoffBuilder;
use connlib_model::{ResourceId, ResourceView};
use firezone_bin_shared::{
    DnsControlMethod, DnsController, TunDeviceManager,
    device_id::{self, DeviceId},
    device_info, known_dirs,
    platform::{tcp_socket_factory, udp_socket_factory},
    signals,
};
use firezone_logging::{FilterReloadHandle, err_with_src, telemetry_span};
use firezone_telemetry::{Telemetry, analytics};
use futures::{
    Future as _, SinkExt as _, Stream, StreamExt,
    future::poll_fn,
    stream::{self, BoxStream},
    task::{Context, Poll},
};
use phoenix_channel::{DeviceInfo, LoginUrl, PhoenixChannel, get_user_agent};
use secrecy::{Secret, SecretString};
use std::{
    collections::BTreeSet,
    io::{self, Write},
    pin::pin,
    sync::Arc,
    time::Duration,
};
use tokio::time::Instant;
use url::Url;

#[cfg(target_os = "linux")]
#[path = "service/linux.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "service/windows.rs"]
mod platform;

#[cfg(target_os = "macos")]
#[path = "service/macos.rs"]
mod platform;

pub use platform::{elevation_check, install, run};

#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
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
    SetDisabledResources(BTreeSet<ResourceId>),
    StartTelemetry {
        environment: String,
        release: String,
        account_slug: Option<String>,
    },
}

/// Messages that end up in the GUI, either forwarded from connlib or from the Tunnel service.
#[derive(Debug, serde::Deserialize, serde::Serialize, strum::Display)]
pub enum ServerMsg {
    Hello,
    /// The Tunnel service finished clearing its log dir.
    ClearedLogs(Result<(), String>),
    ConnectResult(Result<(), String>),
    DisconnectedGracefully,
    OnDisconnect {
        error_msg: String,
        is_authentication_error: bool,
    },
    OnUpdateResources(Vec<ResourceView>),
    /// The Tunnel service is terminating, maybe due to a software update
    ///
    /// This is a hint that the Client should exit with a message like,
    /// "Firezone is updating, please restart the GUI" instead of an error like,
    /// "IPC connection closed".
    TerminatingGracefully,
    /// The interface and tunnel are ready for traffic.
    TunnelReady,
}

impl ServerMsg {
    fn connect_result(result: Result<()>) -> Self {
        Self::ConnectResult(result.map_err(|e| format!("{e:#}")))
    }
}

/// Run the Tunnel service and terminate gracefully if we catch a terminate signal
///
/// If an IPC client is connected when we catch a terminate signal, we send the
/// client a hint about that before we exit.
async fn ipc_listen(
    dns_control_method: DnsControlMethod,
    log_filter_reloader: &FilterReloadHandle,
    signals: &mut signals::Terminate,
) -> Result<()> {
    // Create the device ID and Tunnel service config dir if needed
    // This also gives the GUI a safe place to put the log filter config
    let device_id = device_id::get_or_create().context("Failed to read / create device ID")?;

    let mut server = ipc::Server::new(SocketId::Tunnel)?;
    let mut dns_controller = DnsController { dns_control_method };
    loop {
        let mut handler_fut = pin!(Handler::new(
            device_id.clone(),
            &mut server,
            &mut dns_controller,
            log_filter_reloader,
        ));
        let Some(handler) = poll_fn(|cx| {
            if let Poll::Ready(()) = signals.poll_recv(cx) {
                return Poll::Ready(None);
            }

            if let Poll::Ready(handler) = handler_fut.as_mut().poll(cx) {
                return Poll::Ready(Some(handler));
            }

            Poll::Pending
        })
        .await
        else {
            tracing::info!("Caught SIGINT / SIGTERM / Ctrl+C while waiting on the next client.");
            break;
        };
        let mut handler = match handler {
            Ok(handler) => handler,
            Err(e) => {
                tracing::warn!("Failed to initialise IPC handler: {e:#}");
                continue;
            }
        };
        if let HandlerOk::ServiceTerminating = handler.run(signals).await {
            break;
        }
    }
    Ok(())
}

/// Handles one IPC client
struct Handler<'a> {
    device_id: DeviceId,
    dns_controller: &'a mut DnsController,
    ipc_rx: ipc::ServerRead<ClientMsg>,
    ipc_tx: ipc::ServerWrite<ServerMsg>,
    last_connlib_start_instant: Option<Instant>,
    log_filter_reloader: &'a FilterReloadHandle,
    session: Option<Session>,
    telemetry: Telemetry,
    tun_device: TunDeviceManager,
    dns_notifier: BoxStream<'static, Result<()>>,
    network_notifier: BoxStream<'static, Result<()>>,
}

enum Session {
    Connected {
        event_stream: client_shared::EventStream,
        connlib: client_shared::Session,
    },
    WaitingForNetwork {
        api_url: String,
        token: SecretString,
    },
}

enum Event {
    Connlib(client_shared::Event),
    CallbackChannelClosed,
    Ipc(ClientMsg),
    IpcDisconnected,
    IpcError(anyhow::Error),
    Terminate,
    NetworkChanged(Result<()>),
    DnsChanged(Result<()>),
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
        device_id: DeviceId,
        server: &mut ipc::Server,
        dns_controller: &'a mut DnsController,
        log_filter_reloader: &'a FilterReloadHandle,
    ) -> Result<Self> {
        dns_controller.deactivate()?;

        tracing::info!(
            server_pid = std::process::id(),
            "Listening for GUI to connect over IPC..."
        );

        let (ipc_rx, mut ipc_tx) = server
            .next_client_split()
            .await
            .context("Failed to wait for incoming IPC connection from a GUI")?;
        let tun_device = TunDeviceManager::new(ip_packet::MAX_IP_SIZE, 1)?;
        let dns_notifier = new_dns_notifier().await?.boxed();
        let network_notifier = new_network_notifier().await?.boxed();

        ipc_tx
            .send(&ServerMsg::Hello)
            .await
            .context("Failed to greet to new GUI process")?; // Greet the GUI process. If the GUI process doesn't receive this after connecting, it knows that the tunnel service isn't responding.

        Ok(Self {
            device_id,
            dns_controller,
            ipc_rx,
            ipc_tx,
            last_connlib_start_instant: None,
            log_filter_reloader,
            session: None,
            telemetry: Telemetry::default(),
            tun_device,
            dns_notifier,
            network_notifier,
        })
    }

    /// Run the event loop to communicate with an IPC client.
    ///
    /// If the Tunnel service needs to terminate, we catch that from `signals` and send
    /// the client a hint to shut itself down gracefully.
    ///
    /// The return type is infallible so that we only give up on an IPC client explicitly
    async fn run(&mut self, signals: &mut signals::Terminate) -> HandlerOk {
        let ret = loop {
            match poll_fn(|cx| self.next_event(cx, signals)).await {
                Event::Connlib(x) => {
                    if let Err(error) = self.handle_connlib_event(x).await {
                        tracing::error!("Error while handling connlib callback: {error:#}");
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
                        tracing::error!("Error while handling IPC message from client: {error:#}");
                        continue;
                    }
                }
                Event::IpcDisconnected => {
                    tracing::info!("IPC client disconnected");
                    break HandlerOk::ClientDisconnected;
                }
                Event::IpcError(error) => {
                    tracing::error!("Error while deserializing IPC message: {error:#}");
                    continue;
                }
                Event::Terminate => {
                    tracing::info!(
                        "Caught SIGINT / SIGTERM / Ctrl+C while an IPC client is connected"
                    );
                    // Ignore the result here because we're terminating anyway.
                    let _ = self.send_ipc(ServerMsg::TerminatingGracefully).await;
                    break HandlerOk::ServiceTerminating;
                }
                Event::NetworkChanged(Err(e)) => {
                    tracing::warn!("Error while listening for network change events: {e:#}")
                }
                Event::DnsChanged(Err(e)) => {
                    tracing::warn!("Error while listening for DNS change events: {e:#}")
                }
                Event::NetworkChanged(Ok(())) => {
                    if self.last_connlib_start_instant.is_some() {
                        tracing::debug!("Ignoring network change since we're still signing in");
                        continue;
                    }

                    match self.session.as_ref() {
                        Some(Session::Connected { connlib, .. }) => {
                            connlib.reset();
                        }
                        Some(Session::WaitingForNetwork { api_url, token }) => {
                            tracing::info!("Attempting to re-connect upon network change");

                            let result = self.try_connect(&api_url.clone(), token.clone());

                            if let Some(e) = result
                                .as_ref()
                                .err()
                                .and_then(|e| e.root_cause().downcast_ref::<io::Error>())
                            {
                                tracing::debug!("Still cannot connect to Firezone: {e}");

                                continue;
                            }

                            let msg = match result {
                                Ok(session) => {
                                    self.session = Some(session);

                                    ServerMsg::connect_result(Ok(()))
                                }
                                Err(e) => ServerMsg::connect_result(Err(e)),
                            };

                            let _ = self
                                .ipc_tx
                                .send(&msg)
                                .await
                                .context("Failed to send `ConnectResult`");
                        }
                        None => continue,
                    }
                }
                Event::DnsChanged(Ok(())) => {
                    let Some(Session::Connected { connlib, .. }) = self.session.as_ref() else {
                        continue;
                    };

                    let resolvers = self.dns_controller.system_resolvers();

                    connlib.set_dns(resolvers);
                }
            }
        };

        self.telemetry.stop().await; // Stop the telemetry session once the client disconnects or we are shutting down.

        ret
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

        if let Poll::Ready(Some(result)) = self.network_notifier.poll_next_unpin(cx) {
            return Poll::Ready(Event::NetworkChanged(result));
        }

        if let Poll::Ready(Some(result)) = self.dns_notifier.poll_next_unpin(cx) {
            return Poll::Ready(Event::DnsChanged(result));
        }

        // `FramedRead::next` is cancel-safe.
        if let Poll::Ready(result) = pin!(&mut self.ipc_rx).poll_next(cx) {
            return Poll::Ready(match result {
                Some(Ok(x)) => Event::Ipc(x),
                Some(Err(error)) => Event::IpcError(error),
                None => Event::IpcDisconnected,
            });
        }

        if let Some(Session::Connected { event_stream, .. }) = self.session.as_mut() {
            if let Poll::Ready(option) = event_stream.poll_next(cx) {
                return Poll::Ready(match option {
                    Some(x) => Event::Connlib(x),
                    None => Event::CallbackChannelClosed,
                });
            }
        }

        Poll::Pending
    }

    async fn handle_connlib_event(&mut self, msg: client_shared::Event) -> Result<()> {
        match msg {
            client_shared::Event::Disconnected(error) => {
                let _ = self.session.take();
                self.dns_controller.deactivate()?;
                self.send_ipc(ServerMsg::OnDisconnect {
                    error_msg: error.to_string(),
                    is_authentication_error: error.is_authentication_error(),
                })
                .await?
            }
            client_shared::Event::TunInterfaceUpdated {
                ipv4,
                ipv6,
                dns,
                search_domain,
                ipv4_routes,
                ipv6_routes,
            } => {
                self.tun_device.set_ips(ipv4, ipv6).await?;
                self.dns_controller.set_dns(dns, search_domain).await?;
                if let Some(instant) = self.last_connlib_start_instant.take() {
                    tracing::info!(elapsed = ?instant.elapsed(), "Tunnel ready");
                }
                self.tun_device.set_routes(ipv4_routes, ipv6_routes).await?;
                self.dns_controller.flush()?;

                self.send_ipc(ServerMsg::TunnelReady).await?;
            }
            client_shared::Event::ResourcesUpdated(resources) => {
                // On every resources update, flush DNS to mitigate <https://github.com/firezone/firezone/issues/5052>
                self.dns_controller.flush()?;
                self.send_ipc(ServerMsg::OnUpdateResources(resources))
                    .await?;
            }
        }
        Ok(())
    }

    async fn handle_ipc_msg(&mut self, msg: ClientMsg) -> Result<()> {
        match msg {
            ClientMsg::ClearLogs => {
                let result = logging::clear_service_logs().await;
                self.send_ipc(ServerMsg::ClearedLogs(result.map_err(|e| e.to_string())))
                    .await?
            }
            ClientMsg::Connect { api_url, token } => {
                let token = SecretString::new(token);

                let result = self.try_connect(&api_url, token.clone());

                if let Some(e) = result
                    .as_ref()
                    .err()
                    .and_then(|e| e.root_cause().downcast_ref::<io::Error>())
                {
                    tracing::debug!(
                        "Encountered IO error when connecting to portal, most likely we don't have Internet: {e}"
                    );
                    self.session = Some(Session::WaitingForNetwork { api_url, token });

                    return Ok(());
                }

                let msg = match result {
                    Ok(session) => {
                        self.session = Some(session);

                        ServerMsg::connect_result(Ok(()))
                    }
                    Err(e) => ServerMsg::connect_result(Err(e)),
                };

                self.send_ipc(msg).await?;
            }
            ClientMsg::Disconnect => {
                if self.session.take().is_some() {
                    self.dns_controller.deactivate()?;
                }
                // Always send `DisconnectedGracefully` even if we weren't connected,
                // so this will be idempotent.
                self.send_ipc(ServerMsg::DisconnectedGracefully).await?;
            }
            ClientMsg::ApplyLogFilter { directives } => {
                self.log_filter_reloader.reload(&directives)?;

                let path = known_dirs::tunnel_log_filter()?;

                if let Err(e) = AtomicFile::new(&path, OverwriteBehavior::AllowOverwrite)
                    .write(|f| f.write_all(directives.as_bytes()))
                {
                    tracing::warn!(path = %path.display(), %directives, "Failed to write new log directives: {}", err_with_src(&e));
                }
            }
            ClientMsg::SetDisabledResources(disabled_resources) => {
                let Some(Session::Connected { connlib, .. }) = self.session.as_ref() else {
                    // At this point, the GUI has already saved the disabled Resources to disk, so it'll be correct on the next sign-in anyway.
                    tracing::debug!("Cannot set disabled resources if we're signed out");
                    return Ok(());
                };

                connlib.set_disabled_resources(disabled_resources);
            }
            ClientMsg::StartTelemetry {
                environment,
                release,
                account_slug,
            } => {
                self.telemetry
                    .start(&environment, &release, firezone_telemetry::GUI_DSN);
                Telemetry::set_firezone_id(self.device_id.id.clone());

                if let Some(account_slug) = account_slug {
                    Telemetry::set_account_slug(account_slug);
                }
            }
        }
        Ok(())
    }

    /// Connects connlib
    ///
    /// Panics if there's no Tokio runtime or if connlib is already connected.
    fn try_connect(&mut self, api_url: &str, token: SecretString) -> Result<Session> {
        let _connect_span = telemetry_span!("connect_to_firezone").entered();

        assert!(self.session.is_none());
        let device_id = device_id::get_or_create().context("Failed to get-or-create device ID")?;
        Telemetry::set_firezone_id(device_id.id.clone());

        let url = LoginUrl::client(
            Url::parse(api_url).context("Failed to parse URL")?,
            &token,
            device_id.id.clone(),
            None,
            DeviceInfo {
                device_serial: device_info::serial(),
                device_uuid: device_info::uuid(),
                ..Default::default()
            },
        )
        .context("Failed to create `LoginUrl`")?;

        self.last_connlib_start_instant = Some(Instant::now());

        // Synchronous DNS resolution here
        let portal = PhoenixChannel::disconnected(
            Secret::new(url),
            get_user_agent(None, env!("CARGO_PKG_VERSION")),
            "client",
            (),
            || {
                ExponentialBackoffBuilder::default()
                    .with_max_elapsed_time(Some(Duration::from_secs(60 * 60 * 24 * 30)))
                    .build()
            },
            Arc::new(tcp_socket_factory),
        )?;

        // Read the resolvers before starting connlib, in case connlib's startup interferes.
        let dns = self.dns_controller.system_resolvers();
        let (connlib, event_stream) = client_shared::Session::connect(
            Arc::new(tcp_socket_factory),
            Arc::new(udp_socket_factory),
            portal,
            tokio::runtime::Handle::current(),
        );

        analytics::new_session(device_id.id, api_url.to_string());

        // Call `set_dns` before `set_tun` so that the tunnel starts up with a valid list of resolvers.
        tracing::debug!(?dns, "Calling `set_dns`...");
        connlib.set_dns(dns);

        let tun = {
            let _guard = telemetry_span!("create_tun_device").entered();

            self.tun_device
                .make_tun()
                .context("Failed to create TUN device")?
        };
        connlib.set_tun(tun);

        Ok(Session::Connected {
            event_stream,
            connlib,
        })
    }

    async fn send_ipc(&mut self, msg: ServerMsg) -> Result<()> {
        self.ipc_tx
            .send(&msg)
            .await
            .with_context(|| format!("Failed to send IPC message `{msg}`"))?;

        Ok(())
    }
}

pub fn run_debug(dns_control: DnsControlMethod) -> Result<()> {
    let log_filter_reloader = logging::setup_stdout()?;
    tracing::info!(
        arch = std::env::consts::ARCH,
        version = env!("CARGO_PKG_VERSION"),
        system_uptime_seconds = firezone_bin_shared::uptime::get().map(|dur| dur.as_secs()),
    );
    if !elevation_check()? {
        bail!("Tunnel service failed its elevation check, try running as admin / root");
    }
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let _guard = rt.enter();
    let mut signals = signals::Terminate::new()?;

    rt.block_on(ipc_listen(dns_control, &log_filter_reloader, &mut signals))
}

/// Listen for exactly one connection from a GUI, then exit
///
/// This makes the timing neater in case the GUI starts up slowly.
#[cfg(debug_assertions)]
pub fn run_smoke_test() -> Result<()> {
    use crate::ipc::{self, SocketId};
    use anyhow::{Context as _, bail};
    use firezone_bin_shared::{DnsController, device_id};

    let log_filter_reloader = logging::setup_stdout()?;
    if !elevation_check()? {
        bail!("Tunnel service failed its elevation check, try running as admin / root");
    }
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let _guard = rt.enter();
    let mut dns_controller = DnsController {
        dns_control_method: Default::default(),
    };
    // Deactivate Firezone DNS control in case the system or Tunnel service crashed
    // and we need to recover. <https://github.com/firezone/firezone/issues/4899>
    dns_controller.deactivate()?;
    let mut signals = signals::Terminate::new()?;

    // Couldn't get the loop to work here yet, so SIGHUP is not implemented
    rt.block_on(async {
        let device_id = device_id::get_or_create().context("Failed to read / create device ID")?;
        let mut server = ipc::Server::new(SocketId::Tunnel)?;
        let _ = Handler::new(
            device_id,
            &mut server,
            &mut dns_controller,
            &log_filter_reloader,
        )
        .await?
        .run(&mut signals)
        .await;
        Ok::<_, anyhow::Error>(())
    })
}

#[cfg(not(debug_assertions))]
pub fn run_smoke_test() -> Result<()> {
    anyhow::bail!("Smoke test is not built for release binaries.");
}

async fn new_dns_notifier() -> Result<impl Stream<Item = Result<()>>> {
    let worker = firezone_bin_shared::new_dns_notifier(
        tokio::runtime::Handle::current(),
        DnsControlMethod::default(),
    )
    .await?;

    Ok(stream::try_unfold(worker, |mut worker| async move {
        let () = worker.notified().await?;

        Ok(Some(((), worker)))
    }))
}

async fn new_network_notifier() -> Result<impl Stream<Item = Result<()>>> {
    let worker = firezone_bin_shared::new_network_notifier(
        tokio::runtime::Handle::current(),
        DnsControlMethod::default(),
    )
    .await?;

    Ok(stream::try_unfold(worker, |mut worker| async move {
        let () = worker.notified().await?;

        Ok(Some(((), worker)))
    }))
}
