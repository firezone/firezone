use crate::{
    ipc::{self, SocketId},
    logging,
    settings::{
        AdvancedSettings, MdmSettings, load_advanced_settings, load_mdm_settings, save_advanced,
    },
};
use anyhow::{Context as _, ErrorExt as _, Result, bail};
use backoff::ExponentialBackoffBuilder;
use bin_shared::{
    DnsControlMethod, DnsController, ResumeNotifier, TunDeviceManager,
    device_id::{self, DeviceId},
    device_info,
    platform::{UdpSocketFactory, tcp_socket_factory},
    signals,
};
use client_shared::ConnectedAs;
use connlib_model::{ResourceId, ResourceList};
use futures::{
    Future as _, FutureExt, SinkExt as _, Stream, StreamExt,
    future::poll_fn,
    stream::BoxStream,
    task::{Context, Poll},
};
use ip_network::IpNetwork;
use logging::FilterReloadHandle;
use phoenix_channel::{DeviceInfo, LoginUrl, PhoenixChannel, get_user_agent};
use secrecy::{ExposeSecret, SecretString};
use std::{io, mem, panic::AssertUnwindSafe, pin::pin, sync::Arc, time::Duration};
use telemetry::analytics;
use tokio::time::Instant;
use tracing::Instrument as _;
use tracing_subscriber::EnvFilter;
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

#[cfg(target_os = "windows")]
pub(crate) use platform::ProcessToken;

#[derive(Debug, serde::Deserialize, serde::Serialize)]
pub enum ClientMsg {
    ClearLogs,
    /// Reload the held keystore reference; the result arrives as [`ServerMsg::X509Certificate`].
    ///
    /// Fire-and-forget: the GUI sends it for every shown window and never awaits it.
    ReloadX509,
    Connect {
        authentication: Authentication,
        is_internet_resource_active: bool,
    },
    Disconnect,
    /// Persist new advanced settings to the protected on-disk file owned by
    /// the Tunnel service and reload the log filter.
    ApplyAdvancedSettings(AdvancedSettings),
    SetInternetResourceState(bool),
    StartTelemetry {
        environment: String,
        release: String,
    },
    #[cfg(debug_assertions)]
    Panic,
}

/// What authenticates a session to the portal.
///
/// The certificate itself never crosses this message: the Tunnel service loads it from the
/// platform keystore at connect time, so a variant only states whether to present it.
#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub enum Authentication {
    /// The keystore's certificate alone; its claims name who is connecting.
    Certificate,
    /// A portal token alone.
    Token(#[serde(serialize_with = "serialize_token")] SecretString),
    /// A portal token, with the keystore's certificate alongside for device attestation.
    TokenAndCertificate(#[serde(serialize_with = "serialize_token")] SecretString),
}

fn serialize_token<S>(token: &SecretString, serializer: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    serializer.serialize_str(token.expose_secret())
}

/// Messages that end up in the GUI, either forwarded from connlib or from the Tunnel service.
#[derive(Debug, serde::Deserialize, serde::Serialize, strum::Display)]
pub enum ServerMsg {
    Hello {
        firezone_id: String,
        advanced_settings: AdvancedSettings,
        mdm_settings: MdmSettings,
        x509_certificate: Result<Option<x509_keystore::ParsedCertificate>, x509_keystore::Error>,
    },
    /// The Tunnel service finished clearing its log dir.
    ClearedLogs(Result<(), String>),
    ConnectResult(Result<(), String>),
    DisconnectedGracefully,
    OnDisconnect {
        error_msg: String,
        requires_sign_in: bool,
    },
    AllGatewaysOffline {
        resource_id: ResourceId,
    },
    GatewayVersionMismatch {
        resource_id: ResourceId,
    },
    OnUpdateResources(ResourceList),
    /// Connlib connected to the portal, which named the account and actor this session belongs to.
    ConnectedToPortal(ConnectedAs),
    /// Result of an `ApplyAdvancedSettings` from the GUI. `Ok` echoes the
    /// persisted struct so the GUI is certain about what landed.
    AdvancedSettingsApplied(Result<AdvancedSettings, String>),
    /// What the platform keystore holds, pushed whenever it may have changed.
    ///
    /// `Hello` carries the first load; this arrives for every [`ClientMsg::ReloadX509`] and
    /// whenever we re-read the keystore to sign in, which covers everything the certificate
    /// screen renders.
    X509Certificate(Result<Option<x509_keystore::ParsedCertificate>, x509_keystore::Error>),
    /// The Tunnel service is terminating, maybe due to a software update
    ///
    /// This is a hint that the Client should exit with a message like,
    /// "Firezone is updating, please restart the GUI" instead of an error like,
    /// "IPC connection closed".
    TerminatingGracefully,
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
    socket_id: SocketId,
    signals: &mut signals::Terminate,
) -> Result<()> {
    // Create the device ID and Tunnel service config dir if needed
    // This also gives the GUI a safe place to put the log filter config
    #[cfg(not(test))]
    let device_id =
        device_id::get_or_create_client().context("Failed to read / create device ID")?;

    #[cfg(test)]
    let device_id = device_id::DeviceId::test();

    // Fix up the group of the device ID file and directory so the GUI client can access it.
    #[cfg(target_os = "linux")]
    if device_id.source == device_id::Source::Disk {
        let path = device_id::client_path().context("Failed to access device ID path")?;
        let group_id = crate::firezone_client_group()
            .context("Failed to get `firezone-client` group")?
            .gid
            .as_raw();

        std::os::unix::fs::chown(&path, None, Some(group_id))
            .with_context(|| format!("Failed to change ownership of '{}'", path.display()))?;

        let dir = path.parent().context("No parent path")?;
        std::os::unix::fs::chown(dir, None, Some(group_id))
            .with_context(|| format!("Failed to change ownership of '{}'", dir.display()))?;
    }

    if let Ok(stored) = load_advanced_settings()
        && let Err(e) = log_filter_reloader.reload(&stored.log_filter)
    {
        tracing::warn!("Failed to apply stored log filter: {e:#}");
    }

    // The uploader runs for the lifetime of the process, signed in or not.
    if let Some(dir) = known_dirs::flow_logs() {
        flow_log_upload::spawn(dir, Arc::new(tcp_socket_factory));
    }

    let mut server = ipc::Server::new(socket_id)?;
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

        match AssertUnwindSafe(handler.run(signals)).catch_unwind().await {
            Ok(HandlerOk::ServiceTerminating) => break,
            Ok(HandlerOk::ClientDisconnected | HandlerOk::Err) => {}
            Err(e) => {
                let panic_msg = if let Some(s) = e.downcast_ref::<&str>() {
                    s
                } else if let Some(s) = e.downcast_ref::<String>() {
                    s
                } else {
                    "Unknown"
                };

                tracing::error!("Handler panicked: {panic_msg}")
            }
        }
    }
    Ok(())
}

/// Handles one IPC client
struct Handler<'a> {
    /// The keystore load this GUI connection displays and presents.
    keystore: Result<Option<x509_keystore::Identity>, x509_keystore::Error>,
    device_id: DeviceId,
    dns_controller: &'a mut DnsController,
    ipc_rx: ipc::ServerRead<ClientMsg>,
    ipc_tx: ipc::ServerWrite<ServerMsg>,
    log_filter_reloader: &'a FilterReloadHandle,
    advanced_settings: AdvancedSettings,
    mdm_settings: MdmSettings,
    session: Session,
    telemetry_release: Option<String>,
    tun_device: TunDeviceManager,
    dns_notifier: BoxStream<'static, Result<()>>,
    network_notifier: BoxStream<'static, Result<()>>,
    resume_notifier: ResumeNotifier,
}

#[derive(Default, Debug)]
enum Session {
    /// We've launched `connlib` but haven't heard back from it yet.
    Creating {
        event_stream: client_shared::EventStream,
        connlib: client_shared::Session,
        started_at: Instant,
    },
    Connected {
        event_stream: client_shared::EventStream,
        connlib: client_shared::Session,
    },
    WaitingForNetwork {
        authentication: Authentication,
        is_internet_resource_active: bool,
    },
    #[default]
    None,
}

impl Session {
    fn transition_to_connected(&mut self) -> Result<()> {
        match mem::take(self) {
            Session::Creating {
                event_stream,
                connlib,
                started_at,
            } => {
                tracing::debug!(elapsed = ?started_at.elapsed(), "Tunnel ready");

                *self = Self::Connected {
                    event_stream,
                    connlib,
                };
            }
            Session::Connected {
                event_stream,
                connlib,
            } => {
                *self = Self::Connected {
                    event_stream,
                    connlib,
                };
            }
            Session::WaitingForNetwork { .. } => {
                bail!("Invalid state! Cannot transition into `Connected` from `WaitingForNetwork`")
            }
            Session::None => bail!("No session"),
        }

        Ok(())
    }

    fn as_connlib(&self) -> Option<&client_shared::Session> {
        match self {
            Session::Creating { connlib, .. } => Some(connlib),
            Session::Connected { connlib, .. } => Some(connlib),
            Session::WaitingForNetwork { .. } => None,
            Session::None => None,
        }
    }

    fn as_event_stream(&mut self) -> Option<&mut client_shared::EventStream> {
        match self {
            Session::Creating { event_stream, .. } => Some(event_stream),
            Session::Connected { event_stream, .. } => Some(event_stream),
            Session::WaitingForNetwork { .. } => None,
            Session::None => None,
        }
    }

    fn into_event_stream(self) -> Option<client_shared::EventStream> {
        match self {
            Session::Creating { event_stream, .. } => Some(event_stream),
            Session::Connected { event_stream, .. } => Some(event_stream),
            Session::WaitingForNetwork { .. } => None,
            Session::None => None,
        }
    }

    fn is_none(&self) -> bool {
        matches!(self, Self::None)
    }
}

/// Reads the keystore off the runtime, because it can block on a TPM or a smart card and the
/// connlib eventloop shares this runtime's single worker.
async fn load_identity() -> Result<Option<x509_keystore::Identity>, x509_keystore::Error> {
    let identity = tokio::task::spawn_blocking(x509_keystore::identity)
        .await
        .map_err(|error| x509_keystore::Error::UnreadableKeystore {
            message: format!("Failed to join the keystore task: {error}"),
        })??;

    Ok(identity)
}

/// What the GUI shows of a held keystore load.
fn x509_of(
    keystore: &Result<Option<x509_keystore::Identity>, x509_keystore::Error>,
) -> Result<Option<x509_keystore::ParsedCertificate>, x509_keystore::Error> {
    keystore
        .as_ref()
        .map(|identity| {
            identity
                .as_ref()
                .map(|identity| identity.certificate.clone())
        })
        .map_err(Clone::clone)
}

/// Shuts down the session and waits until its eventloop has exited.
///
/// The eventloop owns the TUN device; only once the event stream ends is the
/// device released and a new session can attach to the interface name again.
async fn shut_down_session(session: Session) {
    const SHUTDOWN_WAIT: Duration = Duration::from_secs(10);

    let Some(mut event_stream) = session.into_event_stream() else {
        return;
    };

    let drained = tokio::time::timeout(SHUTDOWN_WAIT, async {
        loop {
            match event_stream.next().await {
                None => break,
                Some(client_shared::Event::Disconnected(_)) => break,
                Some(_) => {}
            }
        }
    })
    .await;

    if drained.is_err() {
        tracing::warn!("Previous session did not shut down within {SHUTDOWN_WAIT:?}");
    }
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
    Resumed(Result<()>),
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

        tunnel_bypass_resolver::configure(
            Arc::new(tcp_socket_factory),
            Arc::new(UdpSocketFactory::default()),
        );
        telemetry::configure(Arc::new(tcp_socket_factory));

        tracing::info!(
            server_pid = std::process::id(),
            "Listening for GUI to connect over IPC..."
        );

        let (ipc_rx, mut ipc_tx, client_pid) = server
            .next_client_split()
            .await
            .context("Failed to wait for incoming IPC connection from a GUI")?;
        let tun_device = TunDeviceManager::new(ip_packet::MAX_IP_SIZE)?;
        let dns_notifier = bin_shared::new_dns_notifier(
            tokio::runtime::Handle::current(),
            DnsControlMethod::default(),
        )
        .await?
        .boxed();
        let network_notifier = bin_shared::new_network_notifier()
            .await
            .context("Failed to initialize network change monitor")?
            .boxed();
        // Missing resumes only costs us a slower recovery, so don't fail the session over it.
        let resume_notifier = bin_shared::new_resume_notifier()
            .await
            .inspect_err(|e| tracing::warn!("Failed to initialize resume monitor: {e:#}"))
            .unwrap_or_default();

        let advanced_settings = load_advanced_settings()
            .inspect_err(|e| {
                tracing::debug!("Failed to load advanced settings, using defaults: {e:#}")
            })
            .ok()
            .unwrap_or_default();

        // Migrate any per-user MDM policy into the machine-scope location before
        // we read it, so the read below never has to consider the legacy hive.
        #[cfg(target_os = "windows")]
        crate::mdm_migration::run(client_pid);

        #[cfg(not(target_os = "windows"))]
        let _ = client_pid;

        let mdm_settings = load_mdm_settings()
            .inspect_err(|e| tracing::warn!("Failed to load MDM settings, using defaults: {e:#}"))
            .unwrap_or_default();

        // One load serves this GUI connection: the greeting, the page and every connect all
        // read the same held reference, so what is shown is what is presented. Bounded,
        // because a keystore that answers slowly, or never, must not hold up the greeting past
        // the deadline the GUI gives us to prove we are alive.
        let keystore = tokio::time::timeout(Duration::from_secs(3), load_identity())
            .await
            .map_err(|_| x509_keystore::Error::UnreadableKeystore {
                message: "Timed out reading the keystore after 3s".to_owned(),
            })
            .and_then(std::convert::identity);

        ipc_tx
            .send(&ServerMsg::Hello {
                firezone_id: device_id.id.clone(),
                advanced_settings: advanced_settings.clone(),
                mdm_settings: mdm_settings.clone(),
                x509_certificate: x509_of(&keystore),
            })
            .await
            .context("Failed to greet to new GUI process")?; // Greet the GUI process. If the GUI process doesn't receive this after connecting, it knows that the tunnel service isn't responding.

        Ok(Self {
            keystore,
            device_id,
            dns_controller,
            ipc_rx,
            ipc_tx,
            log_filter_reloader,
            advanced_settings,
            mdm_settings,
            session: Session::None,
            telemetry_release: None,
            tun_device,
            dns_notifier,
            network_notifier,
            resume_notifier,
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
                    let span = tracing::error_span!("handle_ipc_msg", msg = %msg_variant);
                    if let Err(error) = self.handle_ipc_msg(msg).instrument(span).await {
                        tracing::error!(%msg_variant, "Error while handling IPC message from client: {error:#}");
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
                Event::Resumed(Err(e)) => {
                    tracing::warn!("Error while listening for resume events: {e:#}")
                }
                Event::NetworkChanged(Ok(())) => self.reset_session("network changed").await,
                Event::Resumed(Ok(())) => self.reset_session("resumed from sleep").await,
                Event::DnsChanged(Ok(())) => {
                    let Session::Connected { connlib, .. } = &self.session else {
                        continue;
                    };

                    let resolvers = self.dns_controller.system_resolvers();

                    connlib.set_dns(resolvers);
                }
            }
        };

        telemetry::stop(); // Flush telemetry as the service shuts down.

        ret
    }

    /// Tells connlib that the network underneath it has changed, or retries the connection if we
    /// were waiting for a network in the first place.
    async fn reset_session(&mut self, reason: &str) {
        match &self.session {
            Session::Creating { .. } => {
                tracing::debug!(%reason, "Ignoring reset since we're still signing in");
            }
            Session::Connected { connlib, .. } => {
                connlib.reset(reason.to_owned());
            }
            Session::WaitingForNetwork {
                authentication,
                is_internet_resource_active,
            } => {
                tracing::info!(%reason, "Attempting to re-connect");

                let authentication = authentication.clone();
                let is_internet_resource_active = *is_internet_resource_active;
                let result = self
                    .try_connect(authentication, is_internet_resource_active)
                    .await;

                if let Some(e) = result
                    .as_ref()
                    .err()
                    .and_then(|e| e.any_downcast_ref::<io::Error>())
                {
                    tracing::debug!("Still cannot connect to Firezone: {e}");

                    return;
                }

                let _ = self.handle_connect_result(result).await;
            }
            Session::None => {}
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

        if let Poll::Ready(Some(result)) = self.network_notifier.poll_next_unpin(cx) {
            return Poll::Ready(Event::NetworkChanged(result));
        }

        if let Poll::Ready(Some(result)) = self.dns_notifier.poll_next_unpin(cx) {
            return Poll::Ready(Event::DnsChanged(result));
        }

        if let Poll::Ready(Some(result)) = self.resume_notifier.poll_next_unpin(cx) {
            return Poll::Ready(Event::Resumed(result));
        }

        // `FramedRead::next` is cancel-safe.
        if let Poll::Ready(result) = pin!(&mut self.ipc_rx).poll_next(cx) {
            return Poll::Ready(match result {
                Some(Ok(x)) => Event::Ipc(x),
                Some(Err(error)) => Event::IpcError(error),
                None => Event::IpcDisconnected,
            });
        }

        if let Some(event_stream) = self.session.as_event_stream()
            && let Poll::Ready(option) = event_stream.poll_next(cx)
        {
            return Poll::Ready(match option {
                Some(x) => Event::Connlib(x),
                None => Event::CallbackChannelClosed,
            });
        }

        Poll::Pending
    }

    /// Re-points telemetry to the neutral environment so events emitted while
    /// disconnected aren't attributed to the ended session.
    fn reset_telemetry_environment(&mut self) {
        if let Some(release) = &self.telemetry_release {
            telemetry::start("entrypoint", release, telemetry::GUI_DSN);
        }
    }

    async fn handle_connlib_event(&mut self, msg: client_shared::Event) -> Result<()> {
        match msg {
            client_shared::Event::Disconnected(error) => {
                self.session = Session::None;
                self.reset_telemetry_environment();
                self.dns_controller.deactivate()?;
                self.send_ipc(ServerMsg::OnDisconnect {
                    error_msg: error.to_string(),
                    requires_sign_in: error.requires_sign_in(),
                })
                .await?
            }
            client_shared::Event::TunInterfaceUpdated(config) => {
                self.session.transition_to_connected()?;

                let tun_ip_stack = self.tun_device.set_ips(config.ip.v4, config.ip.v6).await?;
                self.dns_controller
                    .set_dns(config.dns_by_sentinel.sentinel_ips(), config.search_domain)
                    .await?;
                self.tun_device
                    .set_routes(config.routes.into_iter().filter(|r| match r {
                        IpNetwork::V4(_) => tun_ip_stack.supports_ipv4(),
                        IpNetwork::V6(_) => tun_ip_stack.supports_ipv6(),
                    }))
                    .await?;
                self.dns_controller.flush()?;
            }
            client_shared::Event::AllGatewaysOffline { resource_id } => {
                self.send_ipc(ServerMsg::AllGatewaysOffline { resource_id })
                    .await?;
            }
            client_shared::Event::GatewayVersionMismatch { resource_id } => {
                self.send_ipc(ServerMsg::GatewayVersionMismatch { resource_id })
                    .await?;
            }
            client_shared::Event::ResourcesUpdated(resources) => {
                // On every resources update, flush DNS to mitigate <https://github.com/firezone/firezone/issues/5052>
                self.dns_controller.flush()?;
                self.send_ipc(ServerMsg::OnUpdateResources(resources))
                    .await?;
            }
            client_shared::Event::ConnectedToPortal(connected) => {
                telemetry::set_account_slug(connected.account_slug.clone());

                if let Some(release) = self.telemetry_release.clone() {
                    analytics::identify(release, connected.account_slug.clone(), None, None);
                }

                self.send_ipc(ServerMsg::ConnectedToPortal(connected))
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
            ClientMsg::Connect {
                authentication,
                is_internet_resource_active,
            } => {
                if !self.session.is_none() {
                    tracing::debug!(session = ?self.session, "Dropping existing session before connecting");

                    shut_down_session(mem::take(&mut self.session)).await;
                }

                // The portal names the account in `init`; a session that never gets
                // there must not report the previous one's.
                telemetry::set_account_slug(None);

                let result = self
                    .try_connect(authentication.clone(), is_internet_resource_active)
                    .await;

                if let Some(e) = result
                    .as_ref()
                    .err()
                    .and_then(|e| e.any_downcast_ref::<io::Error>())
                {
                    tracing::debug!(
                        "Encountered IO error when connecting to portal, most likely we don't have Internet: {e}"
                    );
                    self.session = Session::WaitingForNetwork {
                        authentication,
                        is_internet_resource_active,
                    };

                    return Ok(());
                }

                self.handle_connect_result(result).await?;
            }
            ClientMsg::ReloadX509 => {
                self.keystore = load_identity().await;
                self.send_ipc(ServerMsg::X509Certificate(x509_of(&self.keystore)))
                    .await?;
            }
            ClientMsg::Disconnect => {
                self.session = Session::None;
                self.reset_telemetry_environment();
                self.dns_controller.deactivate()?;

                // Always send `DisconnectedGracefully` even if we weren't connected,
                // so this will be idempotent.
                self.send_ipc(ServerMsg::DisconnectedGracefully).await?;
            }
            ClientMsg::ApplyAdvancedSettings(new) => {
                // Validate the log filter before persisting so we never write an
                // unparsable value to disk or report a misleading "saved" to the GUI.
                let response = if let Err(e) = EnvFilter::try_new(&new.log_filter) {
                    Err(format!("Invalid log filter `{}`: {e}", new.log_filter))
                } else {
                    match save_advanced(&new).await {
                        Ok(()) => {
                            let _ = self.log_filter_reloader.reload(&new.log_filter);
                            self.advanced_settings = new.clone();
                            Ok(new)
                        }
                        Err(e) => Err(format!("{e:#}")),
                    }
                };
                self.send_ipc(ServerMsg::AdvancedSettingsApplied(response))
                    .await?;
            }
            ClientMsg::SetInternetResourceState(state) => {
                let Some(connlib) = self.session.as_connlib() else {
                    // At this point, the GUI has already saved the state to disk, so it'll be correct on the next sign-in anyway.
                    tracing::debug!("Cannot enable/disable Internet Resource if we're signed out");
                    return Ok(());
                };

                connlib.set_internet_resource_state(state);
            }
            ClientMsg::StartTelemetry {
                environment,
                release,
            } => {
                // This is a bit hacky.
                // It would be cleaner to pass it down from the `Cli` struct.
                // However, the service can be run in many different ways and adapting all of those
                // is cumbersome.
                // Disabling telemetry for the service is mostly useful for our own testing and therefore
                // doesn't need to be exposed publicly anyway.
                let no_telemetry = crate::NO_TELEMETRY
                    || std::env::var("FIREZONE_NO_TELEMETRY").is_ok_and(|s| s == "true");

                if !no_telemetry {
                    self.telemetry_release = Some(release.clone());
                    telemetry::start(&environment, &release, telemetry::GUI_DSN);
                    telemetry::set_firezone_id(self.device_id.id.clone());

                    opentelemetry::global::set_meter_provider(
                        telemetry::SentryMeterProvider::default(),
                    );

                    analytics::identify(release, None, None, None);
                }
            }
            #[cfg(debug_assertions)]
            ClientMsg::Panic => panic!("Explicit panic"),
        }
        Ok(())
    }

    /// Effective `api_url`: machine-scope MDM policy wins over the stored
    /// advanced setting.
    fn api_url(&self) -> &str {
        self.mdm_settings
            .api_url
            .as_ref()
            .map(|u| u.as_str())
            .unwrap_or_else(|| self.advanced_settings.api_url.as_str())
    }

    /// One keystore read serves the whole attempt: the certificate presented to the portal and
    /// the one pushed to the GUI come from the same walk, so they cannot diverge.
    async fn try_connect(
        &mut self,
        authentication: Authentication,
        is_internet_resource_active: bool,
    ) -> Result<Session> {
        let started_at = Instant::now();

        let device_id =
            device_id::get_or_create_client().context("Failed to get-or-create device ID")?;

        // The certificate the GUI displays is the one this connect presents: both read the
        // held reference, which only a reload replaces. How much the keystore may fail is the
        // intent's to say: a token must not be kept from connecting by a keystore we could not
        // read (without p11-kit, or with only broken PKCS#11 modules, it connects alone while
        // the GUI shows the greeting's error), while a connect the certificate itself
        // authenticates has nothing without it.
        let (token, certificate) = match (authentication, &self.keystore) {
            (Authentication::Certificate, Ok(Some(identity))) => {
                let certificate = identity
                    .client_certificate()
                    .context("Failed to read the platform keystore")?;

                (None, Some(certificate))
            }
            (Authentication::Certificate, Ok(None)) => {
                bail!("Cannot authenticate: the platform keystore holds no client certificate")
            }
            (Authentication::Certificate, Err(error)) => {
                return Err(anyhow::Error::new(error.clone())
                    .context("Failed to read the platform keystore"));
            }
            (Authentication::Token(token), Ok(_)) => (Some(token), None),
            (Authentication::Token(token), Err(_)) => (Some(token), None),
            (Authentication::TokenAndCertificate(token), Ok(Some(identity))) => {
                let certificate = identity
                    .client_certificate()
                    .context("Failed to read the platform keystore")?;

                (Some(token), Some(certificate))
            }
            (Authentication::TokenAndCertificate(token), Ok(None)) => (Some(token), None),
            (
                Authentication::TokenAndCertificate(token),
                Err(
                    x509_keystore::Error::MissingP11Kit
                    | x509_keystore::Error::UnreadablePkcs11Keystore { .. },
                ),
            ) => (Some(token), None),
            (Authentication::TokenAndCertificate(_), Err(error)) => {
                return Err(anyhow::Error::new(error.clone())
                    .context("Failed to read the platform keystore"));
            }
        };

        let api_url = self.api_url().to_string();
        let url = LoginUrl::client(
            Url::parse(&api_url).context("Failed to parse URL")?,
            device_id.id.clone(),
            None,
            DeviceInfo {
                device_serial: device_info::serial(),
                device_uuid: device_info::uuid(),
                ..Default::default()
            },
            certificate,
        )
        .context("Failed to create `LoginUrl`")?;

        let portal = PhoenixChannel::disconnected(
            url,
            token,
            get_user_agent("gui-client", env!("CARGO_PKG_VERSION")),
            "client",
            (),
            || {
                ExponentialBackoffBuilder::default()
                    .with_max_elapsed_time(Some(Duration::from_secs(60 * 60 * 24 * 30)))
                    .build()
            },
            Arc::new(tcp_socket_factory),
        );

        // Read the resolvers before starting connlib, in case connlib's startup interferes.
        let dns = self.dns_controller.system_resolvers();
        let (connlib, event_stream) = client_shared::Session::connect(
            Arc::new(tcp_socket_factory),
            Arc::new(UdpSocketFactory::default()),
            portal,
            is_internet_resource_active,
            dns,
            known_dirs::flow_logs(),
            false,
            tokio::runtime::Handle::current(),
        );

        analytics::new_session(device_id.id, api_url);

        let tun = self
            .tun_device
            .make_tun()
            .context("Failed to create TUN device")?;
        connlib.set_tun(tun);

        Ok(Session::Creating {
            event_stream,
            connlib,
            started_at,
        })
    }

    async fn handle_connect_result(&mut self, result: Result<Session>) -> Result<()> {
        let msg = match result {
            Ok(session) => {
                self.session = session;
                tracing::debug!("Created new session");

                ServerMsg::connect_result(Ok(()))
            }
            Err(e) => {
                tracing::debug!("Failed to create new session: {e:#}");

                ServerMsg::connect_result(Err(e))
            }
        };

        self.send_ipc(msg).await?;

        Ok(())
    }

    async fn send_ipc(&mut self, msg: ServerMsg) -> Result<()> {
        self.ipc_tx
            .send(&msg)
            .await
            .with_context(|| format!("Failed to send IPC message `{msg}`"))?;

        Ok(())
    }
}

/// Run the Tunnel service in an interactive terminal rather than as a
/// background Windows service / systemd unit.
///
/// Mostly used for debugging, but also handy for running a release build
/// interactively, hence it remains available in release builds.
pub fn run_interactive(dns_control: DnsControlMethod, skip_peer_verification: bool) -> Result<()> {
    let log_filter_reloader = logging::setup_stdout()?;
    tracing::info!(
        arch = std::env::consts::ARCH,
        version = env!("CARGO_PKG_VERSION"),
        system_uptime_seconds = bin_shared::uptime::get().map(|dur| dur.as_secs()),
    );

    // Running interactively (e.g. as the local Administrator), the process has
    // neither the `LocalSystem` nor the MSIX package identity, and on Linux the
    // GUI binary usually isn't installed at the canonical path, so the
    // production peer check would reject the connection. `--skip-peer-verification`
    // opts out of that check to pair the interactive tunnel service with a
    // non-installed GUI build. The check still runs by default so it stays
    // testable in debug builds; release builds always keep it.
    #[cfg(debug_assertions)]
    if skip_peer_verification {
        ipc::skip_peer_verification();
    }
    #[cfg(not(debug_assertions))]
    let _ = skip_peer_verification;

    if !elevation_check()? {
        bail!("Tunnel service failed its elevation check, try running as admin / root");
    }
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("connlib")
        .enable_all()
        .build()?;
    let _guard = rt.enter();
    let mut signals = signals::Terminate::new()?;

    rt.block_on(ipc_listen(
        dns_control,
        &log_filter_reloader,
        SocketId::Tunnel,
        &mut signals,
    ))
}

/// Listen for exactly one connection from a GUI, then exit
///
/// This makes the timing neater in case the GUI starts up slowly.
#[cfg(debug_assertions)]
pub fn run_smoke_test() -> Result<()> {
    use crate::ipc::{self, SocketId};
    use anyhow::{Context as _, bail};
    use bin_shared::{DnsController, device_id};

    // The smoke test runs this binary as an unprivileged subprocess of the
    // test runner — not as a Windows service under LocalSystem. Tell the IPC
    // layer to skip pinning/checking LocalSystem ownership on the Tunnel pipe;
    // otherwise `CreateNamedPipeW` fails with `ERROR_INVALID_OWNER`.
    //
    // Windows-only: on Unix the same call disables peer-binary verification,
    // which the smoke test exercises. It installs the GUI at the canonical path
    // for the happy path and launches one from elsewhere to assert the tunnel
    // rejects unrecognised binaries.
    #[cfg(target_os = "windows")]
    ipc::skip_peer_verification();

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
        let device_id =
            device_id::get_or_create_client().context("Failed to read / create device ID")?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn panic_inside_handler_doesnt_interrupt_service() {
        let _guard = logging::test("debug");

        let id = SocketId::Test(rand::random());

        let handle = tokio::spawn(async move {
            let (_, log_filter_reloader) = logging::try_filter::<()>("info").unwrap();
            let mut signals = signals::Terminate::new().unwrap();

            ipc_listen(
                DnsControlMethod::default(),
                &log_filter_reloader,
                id,
                &mut signals,
            )
            .await
        });

        let (_, mut tx) = ipc::connect::<ServerMsg, ClientMsg>(id, ipc::ConnectOptions::default())
            .await
            .unwrap();

        tx.send(&ClientMsg::Panic).await.unwrap();

        let _ = tokio::time::timeout(Duration::from_secs(1), handle)
            .await
            .unwrap_err(); // We want to timeout because that means the task is still running.

        // We can reconnect another instance.
        let (_, _) = ipc::connect::<ServerMsg, ClientMsg>(id, ipc::ConnectOptions::default())
            .await
            .unwrap();
    }
}
