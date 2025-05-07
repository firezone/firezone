use anyhow::{Context as _, Result};
use atomicwrites::{AtomicFile, OverwriteBehavior};
use backoff::ExponentialBackoffBuilder;
use connlib_client_shared::ConnlibMsg;
use firezone_bin_shared::{
    DnsControlMethod, DnsController, TunDeviceManager, device_id, device_info, known_dirs,
    platform::{tcp_socket_factory, udp_socket_factory},
    signals,
};
use firezone_logging::{FilterReloadHandle, err_with_src, telemetry_span};
use firezone_telemetry::Telemetry;
use futures::{
    Future as _, SinkExt as _, Stream as _,
    future::poll_fn,
    task::{Context, Poll},
};
use phoenix_channel::{DeviceInfo, LoginUrl, PhoenixChannel, get_user_agent};
use secrecy::{Secret, SecretString};
use std::{io::Write, pin::pin, sync::Arc, time::Duration};
use tokio::{sync::mpsc, time::Instant};
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

pub use platform::{elevation_check, install_ipc_service, run_ipc_service};

use crate::ipc::{self, ServiceId};

/// Run the IPC service and terminate gracefully if we catch a terminate signal
///
/// If an IPC client is connected when we catch a terminate signal, we send the
/// client a hint about that before we exit.
pub async fn ipc_listen(
    dns_control_method: DnsControlMethod,
    log_filter_reloader: &FilterReloadHandle,
    signals: &mut signals::Terminate,
    telemetry: &mut Telemetry,
) -> Result<()> {
    // Create the device ID and IPC service config dir if needed
    // This also gives the GUI a safe place to put the log filter config
    let firezone_id = device_id::get_or_create()
        .context("Failed to read / create device ID")?
        .id;

    Telemetry::set_firezone_id(firezone_id);

    let mut server = ipc::Server::new(ServiceId::Prod).await?;
    let mut dns_controller = DnsController { dns_control_method };
    loop {
        let mut handler_fut = pin!(Handler::new(
            &mut server,
            &mut dns_controller,
            log_filter_reloader,
            telemetry,
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
    log_filter_reloader: &'a FilterReloadHandle,
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
    Ipc(ipc::ClientMsg),
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
        server: &mut ipc::Server,
        dns_controller: &'a mut DnsController,
        log_filter_reloader: &'a FilterReloadHandle,
        telemetry: &'a mut Telemetry,
    ) -> Result<Self> {
        dns_controller.deactivate()?;
        let (ipc_rx, ipc_tx) = server
            .next_client_split()
            .await
            .context("Failed to wait for incoming IPC connection from a GUI")?;
        let tun_device = TunDeviceManager::new(ip_packet::MAX_IP_SIZE, 1)?;

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
                    let _ = self.send_ipc(ipc::ServerMsg::TerminatingGracefully).await;
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
                let _ = self.session.take();
                self.dns_controller.deactivate()?;
                self.send_ipc(ipc::ServerMsg::OnDisconnect {
                    error_msg,
                    is_authentication_error,
                })
                .await?
            }
            ConnlibMsg::OnSetInterfaceConfig {
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

                self.send_ipc(ipc::ServerMsg::TunnelReady).await?;
            }
            ConnlibMsg::OnUpdateResources(resources) => {
                // On every resources update, flush DNS to mitigate <https://github.com/firezone/firezone/issues/5052>
                self.dns_controller.flush()?;
                self.send_ipc(ipc::ServerMsg::OnUpdateResources(resources))
                    .await?;
            }
        }
        Ok(())
    }

    async fn handle_ipc_msg(&mut self, msg: ipc::ClientMsg) -> Result<()> {
        match msg {
            ipc::ClientMsg::ClearLogs => {
                let result = crate::clear_logs(
                    &firezone_bin_shared::known_dirs::ipc_service_logs()
                        .context("Can't compute logs dir")?,
                )
                .await;
                self.send_ipc(ipc::ServerMsg::ClearedLogs(
                    result.map_err(|e| e.to_string()),
                ))
                .await?
            }
            ipc::ClientMsg::Connect { api_url, token } => {
                // Warning: Connection errors don't bubble to callers of `handle_ipc_msg`.
                let token = secrecy::SecretString::from(token);
                let result = self.connect_to_firezone(&api_url, token);

                self.send_ipc(ipc::ServerMsg::ConnectResult(result)).await?
            }
            ipc::ClientMsg::Disconnect => {
                if self.session.take().is_some() {
                    self.dns_controller.deactivate()?;
                }
                // Always send `DisconnectedGracefully` even if we weren't connected,
                // so this will be idempotent.
                self.send_ipc(ipc::ServerMsg::DisconnectedGracefully)
                    .await?;
            }
            ipc::ClientMsg::ApplyLogFilter { directives } => {
                self.log_filter_reloader.reload(&directives)?;

                let path = known_dirs::ipc_log_filter()?;

                if let Err(e) = AtomicFile::new(&path, OverwriteBehavior::AllowOverwrite)
                    .write(|f| f.write_all(directives.as_bytes()))
                {
                    tracing::warn!(path = %path.display(), %directives, "Failed to write new log directives: {}", err_with_src(&e));
                }
            }
            ipc::ClientMsg::Reset => {
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
            ipc::ClientMsg::SetDns(resolvers) => {
                let Some(session) = self.session.as_ref() else {
                    tracing::debug!("Cannot set DNS resolvers if we're signed out");
                    return Ok(());
                };

                tracing::debug!(?resolvers);
                session.connlib.set_dns(resolvers);
            }
            ipc::ClientMsg::SetDisabledResources(disabled_resources) => {
                let Some(session) = self.session.as_ref() else {
                    // At this point, the GUI has already saved the disabled Resources to disk, so it'll be correct on the next sign-in anyway.
                    tracing::debug!("Cannot set disabled resources if we're signed out");
                    return Ok(());
                };

                session.connlib.set_disabled_resources(disabled_resources);
            }
            ipc::ClientMsg::StartTelemetry {
                environment,
                release,
                account_slug,
            } => {
                self.telemetry
                    .start(&environment, &release, firezone_telemetry::GUI_DSN);

                if let Some(account_slug) = account_slug {
                    Telemetry::set_account_slug(account_slug);
                }
            }
        }
        Ok(())
    }

    /// Connects connlib
    ///
    /// Panics if there's no Tokio runtime or if connlib is already connected
    ///
    /// Throws matchable errors for bad URLs, unable to reach the portal, or unable to create the tunnel device
    fn connect_to_firezone(
        &mut self,
        api_url: &str,
        token: SecretString,
    ) -> Result<(), ipc::Error> {
        let _connect_span = telemetry_span!("connect_to_firezone").entered();

        assert!(self.session.is_none());
        let device_id = device_id::get_or_create().context("Failed to get-or-create device ID")?;
        Telemetry::set_firezone_id(device_id.id.clone());

        let url = LoginUrl::client(
            Url::parse(api_url).context("Failed to parse URL")?,
            &token,
            device_id.id,
            None,
            DeviceInfo {
                device_serial: device_info::serial(),
                device_uuid: device_info::uuid(),
                ..Default::default()
            },
        )
        .context("Failed to create `LoginUrl`")?;

        self.last_connlib_start_instant = Some(Instant::now());
        let (callbacks, cb_rx) = connlib_client_shared::ChannelCallbackHandler::new();

        // Synchronous DNS resolution here
        let portal = PhoenixChannel::disconnected(
            Secret::new(url),
            // The IPC service must use the GUI's version number, not the Headless Client's.
            // But refactoring to separate the IPC service from the Headless Client will take a while.
            // mark:next-gui-version
            get_user_agent(None, "1.4.13"),
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
        connlib.set_tun(tun);

        let session = Session { cb_rx, connlib };
        self.session = Some(session);

        Ok(())
    }

    async fn send_ipc(&mut self, msg: ipc::ServerMsg) -> Result<()> {
        self.ipc_tx
            .send(&msg)
            .await
            .with_context(|| format!("Failed to send IPC message `{msg}`"))?;

        Ok(())
    }
}

/// Listen for exactly one connection from a GUI, then exit
///
/// This makes the timing neater in case the GUI starts up slowly.
#[cfg(debug_assertions)]
pub fn run_smoke_test() -> Result<()> {
    use crate::ipc::{self, ServiceId};
    use anyhow::{Context as _, bail};
    use firezone_bin_shared::{DnsController, device_id};

    let log_filter_reloader = crate::logging::setup_stdout()?;
    if !elevation_check()? {
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
        let mut server = ipc::Server::new(ServiceId::Prod).await?;
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

#[cfg(not(debug_assertions))]
pub fn run_smoke_test() -> Result<()> {
    anyhow::bail!("Smoke test is not built for release binaries.");
}
