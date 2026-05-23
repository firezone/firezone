use crate::{
    ipc::{self, SocketId},
    logging,
};
use anyhow::{Context as _, ErrorExt as _, Result, bail};
use atomicwrites::{AtomicFile, OverwriteBehavior};
use backoff::ExponentialBackoffBuilder;
use bin_shared::{
    DnsControlMethod, DnsController, TunDeviceManager,
    device_id::{self, DeviceId},
    device_info,
    platform::{UdpSocketFactory, tcp_socket_factory},
    signals,
};
use connlib_model::{ResourceId, ResourceList};
use futures::{
    Future as _, FutureExt, SinkExt as _, Stream, StreamExt,
    future::poll_fn,
    stream::BoxStream,
    task::{Context, Poll},
};
use ip_network::IpNetwork;
use logging::{FilterReloadHandle, err_with_src};
use phoenix_channel::{DeviceInfo, LoginUrl, PhoenixChannel, get_user_agent};
use secrecy::{ExposeSecret, SecretString};
use std::{
    io::{self, Write},
    mem,
    panic::AssertUnwindSafe,
    pin::pin,
    sync::Arc,
    time::Duration,
};
use telemetry::{Telemetry, analytics, otel};
use tokio::time::Instant;
use tracing::Instrument as _;
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

/// Whether the Tunnel service is running in scripted mock mode.
///
/// In mock mode, `Connect` is stubbed out (no connlib / portal session) and a
/// canned `ResourceList` is emitted, so the GUI's real controller / IPC paths
/// can be exercised offline. Debug builds only.
#[cfg(debug_assertions)]
static MOCK: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Set [`MOCK`].
///
/// Call once at process startup, before serving any client.
#[cfg(debug_assertions)]
pub fn enable_mock() {
    MOCK.store(true, std::sync::atomic::Ordering::Relaxed);
}

#[cfg(debug_assertions)]
fn is_mock() -> bool {
    MOCK.load(std::sync::atomic::Ordering::Relaxed)
}

/// Canned resources + connected devices served in mock mode: 5 resources
/// (Internet, two CIDR incl. one Offline, two DNS incl. one Unknown) and 22
/// connected devices with rotating pool membership, so every tray rendering
/// branch is exercised.
#[cfg(debug_assertions)]
fn mock_resource_list() -> ResourceList {
    use connlib_model::{
        CidrResourceView, ClientId, ConnectedDeviceView, DnsResourceView, InternetResourceView,
        ResourceStatus, ResourceView, Site, SiteId,
    };
    use std::net::Ipv4Addr;

    let site = Site {
        id: SiteId::from_u128(0xDEAD_BEEF),
        name: "Demo Site".into(),
    };
    let resources = vec![
        // Internet resource sorts first in connlib (`ResourceView`'s `Ord`
        // impl in connlib_model::view), so the fixture mirrors that order.
        ResourceView::Internet(InternetResourceView {
            id: ResourceId::from_u128(0x103),
            name: "Internet Resource".into(),
            sites: vec![site.clone()],
            status: ResourceStatus::Online,
        }),
        ResourceView::Cidr(CidrResourceView {
            id: ResourceId::from_u128(0x101),
            address: "10.0.0.0/16"
                .parse::<IpNetwork>()
                .expect("hardcoded CIDR is valid"),
            name: "Office network".into(),
            address_description: Some("CIDR resource".into()),
            sites: vec![site.clone()],
            status: ResourceStatus::Online,
        }),
        ResourceView::Dns(DnsResourceView {
            id: ResourceId::from_u128(0x102),
            address: "gitlab.demo.example".into(),
            name: "Demo GitLab".into(),
            address_description: Some("https://gitlab.demo.example".into()),
            sites: vec![site.clone()],
            status: ResourceStatus::Online,
        }),
        ResourceView::Cidr(CidrResourceView {
            id: ResourceId::from_u128(0x104),
            address: "192.168.50.0/24"
                .parse::<IpNetwork>()
                .expect("hardcoded CIDR is valid"),
            name: "Lab network (offline)".into(),
            address_description: Some("Gateway offline".into()),
            sites: vec![site.clone()],
            status: ResourceStatus::Offline,
        }),
        ResourceView::Dns(DnsResourceView {
            id: ResourceId::from_u128(0x105),
            address: "wiki.demo.example".into(),
            name: "Demo Wiki (unknown)".into(),
            address_description: Some("Gateway state unknown".into()),
            sites: vec![site],
            status: ResourceStatus::Unknown,
        }),
    ];

    const POOL_PATTERNS: &[&[&str]] = &[
        &["Engineering Pool"],
        &["Engineering Pool", "QA Pool"],
        &["QA Pool"],
        &["Sales Pool"],
    ];
    let connected_devices = (0..22u128)
        .map(|i| ConnectedDeviceView {
            id: ClientId::from_u128(i + 1),
            tunneled_ipv4: Ipv4Addr::new(100, 96, 0, (i as u8) + 1),
            pools: POOL_PATTERNS[(i as usize) % POOL_PATTERNS.len()]
                .iter()
                .map(|name| (*name).to_string())
                .collect(),
        })
        .collect();

    ResourceList {
        resources,
        connected_devices,
    }
}

#[derive(Debug, serde::Deserialize, serde::Serialize)]
pub enum ClientMsg {
    ClearLogs,
    Connect {
        api_url: String,
        #[serde(serialize_with = "serialize_token")]
        token: SecretString,
        is_internet_resource_active: bool,
    },
    Disconnect,
    ApplyLogFilter {
        directives: String,
    },
    SetInternetResourceState(bool),
    StartTelemetry {
        environment: String,
        release: String,
        account_slug: Option<String>,
    },
    #[cfg(debug_assertions)]
    Panic,
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
    /// First message sent on every IPC connection.
    ///
    /// Includes the Firezone ID so the GUI can use it for telemetry without
    /// having to read the on-disk file (which is locked-down to System and
    /// Administrators on Windows).
    Hello {
        firezone_id: String,
    },
    /// The Tunnel service finished clearing its log dir.
    ClearedLogs(Result<(), String>),
    ConnectResult(Result<(), String>),
    DisconnectedGracefully,
    OnDisconnect {
        error_msg: String,
        is_authentication_error: bool,
    },
    AllGatewaysOffline {
        resource_id: ResourceId,
    },
    GatewayVersionMismatch {
        resource_id: ResourceId,
    },
    OnUpdateResources(ResourceList),
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
    device_id: DeviceId,
    dns_controller: &'a mut DnsController,
    ipc_rx: ipc::ServerRead<ClientMsg>,
    ipc_tx: ipc::ServerWrite<ServerMsg>,
    log_filter_reloader: &'a FilterReloadHandle,
    session: Session,
    telemetry: Telemetry,
    tun_device: TunDeviceManager,
    dns_notifier: BoxStream<'static, Result<()>>,
    network_notifier: BoxStream<'static, Result<()>>,
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
        api_url: String,
        token: SecretString,
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

    fn is_none(&self) -> bool {
        matches!(self, Self::None)
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

        let telemetry = Telemetry::new();

        tracing::info!(
            server_pid = std::process::id(),
            "Listening for GUI to connect over IPC..."
        );

        let (ipc_rx, mut ipc_tx) = server
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

        ipc_tx
            .send(&ServerMsg::Hello {
                firezone_id: device_id.id.clone(),
            })
            .await
            .context("Failed to greet to new GUI process")?; // Greet the GUI process. If the GUI process doesn't receive this after connecting, it knows that the tunnel service isn't responding.

        Ok(Self {
            device_id,
            dns_controller,
            ipc_rx,
            ipc_tx,
            log_filter_reloader,
            session: Session::None,
            telemetry,
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
                Event::NetworkChanged(Ok(())) => match &self.session {
                    Session::Creating { .. } => {
                        tracing::debug!("Ignoring network change since we're still signing in");
                    }
                    Session::Connected { connlib, .. } => {
                        connlib.reset("network changed".to_owned());
                    }
                    Session::WaitingForNetwork {
                        api_url,
                        token,
                        is_internet_resource_active,
                    } => {
                        tracing::info!("Attempting to re-connect upon network change");

                        let result = self.try_connect(
                            &api_url.clone(),
                            token.clone(),
                            *is_internet_resource_active,
                        );

                        if let Some(e) = result
                            .as_ref()
                            .err()
                            .and_then(|e| e.any_downcast_ref::<io::Error>())
                        {
                            tracing::debug!("Still cannot connect to Firezone: {e}");

                            continue;
                        }

                        let _ = self.handle_connect_result(result).await;
                    }
                    Session::None => continue,
                },
                Event::DnsChanged(Ok(())) => {
                    let Session::Connected { connlib, .. } = &self.session else {
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

    async fn handle_connlib_event(&mut self, msg: client_shared::Event) -> Result<()> {
        match msg {
            client_shared::Event::Disconnected(error) => {
                self.session = Session::None;
                self.telemetry.stop().await;
                self.dns_controller.deactivate()?;
                self.send_ipc(ServerMsg::OnDisconnect {
                    error_msg: error.to_string(),
                    is_authentication_error: error.is_authentication_error(),
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
                api_url,
                token,
                is_internet_resource_active,
            } => {
                #[cfg(debug_assertions)]
                if is_mock() {
                    // Stub the session out entirely: stay `Session::None` (no TUN
                    // device, no connlib, no DNS routes) and feed the GUI the same
                    // `ConnectResult(Ok)` -> `OnUpdateResources` sequence a real
                    // connect would, so its status machine reaches `TunnelReady`.
                    self.send_ipc(ServerMsg::connect_result(Ok(()))).await?;
                    self.send_ipc(ServerMsg::OnUpdateResources(mock_resource_list()))
                        .await?;
                    return Ok(());
                }

                if !self.session.is_none() {
                    tracing::debug!(session = ?self.session, "Connecting despite existing session");
                }

                let result = self.try_connect(&api_url, token.clone(), is_internet_resource_active);

                if let Some(e) = result
                    .as_ref()
                    .err()
                    .and_then(|e| e.any_downcast_ref::<io::Error>())
                {
                    tracing::debug!(
                        "Encountered IO error when connecting to portal, most likely we don't have Internet: {e}"
                    );
                    self.session = Session::WaitingForNetwork {
                        api_url,
                        token,
                        is_internet_resource_active,
                    };

                    return Ok(());
                }

                self.handle_connect_result(result).await?;
            }
            ClientMsg::Disconnect => {
                self.session = Session::None;
                self.telemetry.stop().await;
                self.dns_controller.deactivate()?;

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
                account_slug,
            } => {
                // This is a bit hacky.
                // It would be cleaner to pass it down from the `Cli` struct.
                // However, the service can be run in many different ways and adapting all of those
                // is cumbersome.
                // Disabling telemetry for the service is mostly useful for our own testing and therefore
                // doesn't need to be exposed publicly anyway.
                let no_telemetry =
                    std::env::var("FIREZONE_NO_TELEMETRY").is_ok_and(|s| s == "true");

                if !no_telemetry {
                    self.telemetry
                        .start(&environment, &release, telemetry::GUI_DSN);
                    Telemetry::set_firezone_id(self.device_id.id.clone()).await;

                    otel::install_sentry_meter_provider(
                        env!("CARGO_PKG_NAME"),
                        env!("CARGO_PKG_VERSION"),
                        self.device_id.id.clone(),
                    );

                    if let Some(account_slug) = account_slug {
                        Telemetry::set_account_slug(account_slug.clone());

                        analytics::identify(release, Some(account_slug));
                    }
                }
            }
            #[cfg(debug_assertions)]
            ClientMsg::Panic => panic!("Explicit panic"),
        }
        Ok(())
    }

    fn try_connect(
        &mut self,
        api_url: &str,
        token: SecretString,
        is_internet_resource_active: bool,
    ) -> Result<Session> {
        let started_at = Instant::now();

        let device_id =
            device_id::get_or_create_client().context("Failed to get-or-create device ID")?;

        let url = LoginUrl::client(
            Url::parse(api_url).context("Failed to parse URL")?,
            device_id.id.clone(),
            None,
            DeviceInfo {
                device_serial: device_info::serial(),
                device_uuid: device_info::uuid(),
                ..Default::default()
            },
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
            tokio::runtime::Handle::current(),
        );

        analytics::new_session(device_id.id, api_url.to_string());

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

pub fn run_debug(dns_control: DnsControlMethod) -> Result<()> {
    let log_filter_reloader = logging::setup_stdout()?;
    tracing::info!(
        arch = std::env::consts::ARCH,
        version = env!("CARGO_PKG_VERSION"),
        system_uptime_seconds = bin_shared::uptime::get().map(|dur| dur.as_secs()),
    );
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
    // otherwise `CreateNamedPipeW` fails with `ERROR_INVALID_OWNER` on Windows.
    ipc::skip_tunnel_pipe_owner_check();

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
