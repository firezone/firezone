use crate::{
    auth, deep_link,
    gui::{self, system_tray},
    ipc::{self, SocketId},
    logging::{self, FileCount},
    service,
    settings::{self, AdvancedSettings, GeneralSettings, MdmSettings},
    updates, uptime,
    view::{GeneralSettingsForm, SessionViewModel},
};
use anyhow::{Context, ErrorExt as _, Result, anyhow, bail};
use connlib_model::ResourceView;
use futures::{
    SinkExt, StreamExt,
    stream::{self, BoxStream},
};
use logging::FilterReloadHandle;
use secrecy::{ExposeSecret as _, SecretString};
use std::{ops::ControlFlow, path::PathBuf, task::Poll, time::Duration};
use telemetry::Telemetry;
use tokio::sync::{mpsc, oneshot};
use tokio_stream::wrappers::ReceiverStream;
use url::Url;

mod ran_before;

pub struct Controller<I: GuiIntegration> {
    general_settings: GeneralSettings,
    mdm_settings: MdmSettings,
    advanced_settings: AdvancedSettings,
    // Sign-in state with the portal / deep links
    auth: auth::Auth,
    clear_logs_callback: Option<oneshot::Sender<Result<(), String>>>,
    ctrl_tx: mpsc::Sender<ControllerRequest>,
    ipc_client: ipc::ClientWrite<service::ClientMsg>,
    ipc_rx: ipc::ClientRead<service::ServerMsg>,
    integration: I,
    log_filter_reloader: FilterReloadHandle,
    /// A release that's ready to download
    release: Option<updates::Release>,
    ctrl_rx: ReceiverStream<ControllerRequest>,
    status: Status,
    updates_rx: ReceiverStream<Option<updates::Notification>>,
    uptime: uptime::Tracker,

    gui_ipc_clients: BoxStream<
        'static,
        Result<(
            ipc::ServerRead<gui::ClientMsg>,
            ipc::ServerWrite<gui::ServerMsg>,
        )>,
    >,
}

pub trait GuiIntegration {
    fn notify_session_changed(&self, session: &SessionViewModel) -> Result<()>;
    fn notify_settings_changed(
        &self,
        mdm_settings: MdmSettings,
        general_settings: GeneralSettings,
        advanced_settings: AdvancedSettings,
    ) -> Result<()>;
    fn notify_logs_recounted(&self, file_count: &FileCount) -> Result<()>;

    /// Also opens non-URLs
    fn open_url<P: AsRef<str>>(&self, url: P) -> Result<()>;

    fn set_tray_icon(&mut self, icon: system_tray::Icon);
    fn set_tray_menu(&mut self, app_state: system_tray::AppState);
    fn show_notification(
        &self,
        title: impl Into<String>,
        body: impl Into<String>,
    ) -> Result<NotificationHandle>;

    fn set_window_visible(&self, visible: bool) -> Result<()>;
    fn show_overview_page(&self, session: &SessionViewModel) -> Result<()>;
    fn show_settings_page(
        &self,
        mdm_settings: MdmSettings,
        general_settings: GeneralSettings,
        settings: AdvancedSettings,
    ) -> Result<()>;
    fn show_about_page(&self) -> Result<()>;
}

pub struct NotificationHandle {
    pub on_click: futures::channel::oneshot::Receiver<()>,
}

#[derive(strum::Display)]
pub enum ControllerRequest {
    ApplyAdvancedSettings(Box<AdvancedSettings>),
    ApplyGeneralSettings(Box<GeneralSettingsForm>),
    ResetGeneralSettings,
    /// Clear the GUI's logs and await the Tunnel service to clear its logs
    ClearLogs(oneshot::Sender<Result<(), String>>),
    /// The same as the arguments to `client::logging::export_logs_to`
    ExportLogs {
        path: PathBuf,
        stem: PathBuf,
    },
    Fail(Failure),
    SignIn,
    SignOut,
    UpdateState,
    SystemTrayMenu(system_tray::Event),
    UpdateNotificationClicked(Url),
}

// The failure flags are all mutually exclusive
// TODO: I can't figure out from the `clap` docs how to do this:
// `app --fail-on-purpose crash-in-wintun-worker`
// So the failure should be an `Option<Enum>` but _not_ a subcommand.
// You can only have one subcommand per container, I've tried
#[derive(Debug)]
pub enum Failure {
    Crash,
    Error,
    Panic,
}

#[derive(derive_more::Debug, Default)]
pub enum Status {
    /// Firezone is disconnected.
    #[default]
    Disconnected,
    Quitting, // The user asked to quit and we're waiting for the tunnel daemon to gracefully disconnect so we can flush telemetry.
    /// Firezone is ready to use.
    TunnelReady {
        #[debug(skip)]
        resources: Vec<ResourceView>,
    },
    /// Firezone is signing in to the Portal.
    WaitingForPortal,
    /// Firezone has connected to the Portal and is raising the tunnel.
    WaitingForTunnel,
}

impl Status {
    /// True if we should react to `OnUpdateResources`
    fn needs_resource_updates(&self) -> bool {
        match self {
            Status::Disconnected | Status::Quitting | Status::WaitingForPortal => false,
            Status::TunnelReady { .. } | Status::WaitingForTunnel => true,
        }
    }
}

enum EventloopTick {
    IpcMsg(Option<Result<service::ServerMsg>>),
    ControllerRequest(Option<ControllerRequest>),
    UpdateNotification(Option<updates::Notification>),
    NewInstanceLaunched(
        Option<
            Result<(
                ipc::ServerRead<gui::ClientMsg>,
                ipc::ServerWrite<gui::ServerMsg>,
            )>,
        >,
    ),
}

#[derive(Debug, thiserror::Error)]
#[error("Failed to receive hello: {0:#}")]
pub struct FailedToReceiveHello(anyhow::Error);

impl<I: GuiIntegration> Controller<I> {
    pub(crate) async fn start(
        socket: SocketId,
        integration: I,
        ctrl_tx: mpsc::Sender<ControllerRequest>,
        ctrl_rx: mpsc::Receiver<ControllerRequest>,
        general_settings: GeneralSettings,
        mdm_settings: MdmSettings,
        advanced_settings: AdvancedSettings,
        log_filter_reloader: FilterReloadHandle,
        updates_rx: mpsc::Receiver<Option<updates::Notification>>,
        gui_ipc: ipc::Server,
    ) -> Result<()> {
        tracing::debug!("Starting new instance of `Controller`");

        let (mut ipc_rx, ipc_client) = ipc::connect(socket, ipc::ConnectOptions::default()).await?;

        receive_hello(&mut ipc_rx)
            .await
            .map_err(FailedToReceiveHello)?;

        let controller = Controller {
            general_settings,
            mdm_settings,
            advanced_settings,
            auth: auth::Auth::new()?,
            clear_logs_callback: None,
            ctrl_tx,
            ipc_client,
            ipc_rx,
            integration,
            log_filter_reloader,
            release: None,
            ctrl_rx: ReceiverStream::new(ctrl_rx),
            status: Default::default(),
            updates_rx: ReceiverStream::new(updates_rx),
            uptime: Default::default(),
            gui_ipc_clients: stream::unfold(gui_ipc, |mut gui_ipc| async move {
                let result = gui_ipc.next_client_split().await;

                Some((result, gui_ipc))
            })
            .boxed(),
        };

        controller.main_loop().await?;

        Ok(())
    }

    pub async fn main_loop(mut self) -> Result<()> {
        self.update_telemetry_context().await?;

        if let Some(token) = self
            .auth
            .token()
            .context("Failed to load token from disk during app start")?
        {
            // For backwards-compatibility prior to MDM-config, also call `start_session` if not configured.
            if self.connect_on_start().is_none_or(|c| c) {
                self.start_session(token).await?;
            }
        } else {
            tracing::info!("No token / actor_name on disk, starting in signed-out state");
        }

        self.refresh_ui_state();

        if !ran_before::get().await? || !self.general_settings.start_minimized {
            let (_, session_view_model) = self.build_ui_state();

            self.integration.show_overview_page(&session_view_model)?;
        }

        loop {
            match self.tick().await {
                EventloopTick::IpcMsg(msg) => {
                    let msg = msg
                        .context("IPC closed")?
                        .context("Failed to read from IPC")?;

                    match self.handle_service_ipc_msg(msg).await? {
                        ControlFlow::Break(()) => break,
                        ControlFlow::Continue(()) => continue,
                    };
                }

                EventloopTick::ControllerRequest(Some(req)) => self.handle_request(req).await?,
                EventloopTick::ControllerRequest(None) => {
                    tracing::warn!("Controller channel closed, breaking main loop");
                    break;
                }
                EventloopTick::UpdateNotification(notification) => {
                    self.handle_update_notification(notification)?
                }
                EventloopTick::NewInstanceLaunched(None) => {
                    return Err(anyhow!("GUI IPC socket closed"));
                }
                EventloopTick::NewInstanceLaunched(Some(Err(e))) => {
                    tracing::warn!("Failed to accept IPC connection from new GUI instance: {e:#}");
                }
                EventloopTick::NewInstanceLaunched(Some(Ok((mut read, mut write)))) => {
                    let client_msg = read.next().await;

                    if let Err(e) = self.handle_gui_ipc_msg(client_msg).await {
                        tracing::debug!("Failed to handle IPC message from new GUI instance: {e:#}")
                    }

                    if let Err(e) = write.send(&gui::ServerMsg::Ack).await {
                        tracing::debug!("Failed to ack IPC message from new GUI instance: {e:#}")
                    }
                }
            }
        }

        tracing::debug!("Closing...");

        if let Err(error) = self.ipc_client.close().await {
            tracing::error!("ipc_client: {error:#}");
        }

        // Don't close telemetry here, `run` will close it.

        Ok(())
    }

    async fn tick(&mut self) -> EventloopTick {
        std::future::poll_fn(|cx| {
            if let Poll::Ready(maybe_ipc) = self.ipc_rx.poll_next_unpin(cx) {
                return Poll::Ready(EventloopTick::IpcMsg(maybe_ipc));
            }

            if let Poll::Ready(maybe_req) = self.ctrl_rx.poll_next_unpin(cx) {
                return Poll::Ready(EventloopTick::ControllerRequest(maybe_req));
            }

            if let Poll::Ready(new_instance) = self.gui_ipc_clients.poll_next_unpin(cx) {
                return Poll::Ready(EventloopTick::NewInstanceLaunched(new_instance));
            }

            if let Poll::Ready(Some(notification)) = self.updates_rx.poll_next_unpin(cx) {
                return Poll::Ready(EventloopTick::UpdateNotification(notification));
            }

            Poll::Pending
        })
        .await
    }

    async fn start_session(&mut self, token: SecretString) -> Result<()> {
        match self.status {
            Status::Disconnected => {}
            Status::Quitting => Err(anyhow!("Can't connect to Firezone, we're quitting"))?,
            Status::TunnelReady { .. } => Err(anyhow!(
                "Can't connect to Firezone, we're already connected."
            ))?,
            Status::WaitingForPortal | Status::WaitingForTunnel => Err(anyhow!(
                "Can't connect to Firezone, we're already connecting."
            ))?,
        }

        let api_url = self.api_url().clone();
        tracing::info!(api_url = api_url.to_string(), "Starting connlib...");

        self.send_ipc(&service::ClientMsg::Connect {
            api_url: api_url.to_string(),
            token,
            is_internet_resource_active: self.general_settings.internet_resource_enabled(),
        })
        .await?;

        // Change the status after we begin connecting
        self.status = Status::WaitingForPortal;

        let session = self.auth.session().context("Missing session")?;

        self.general_settings.account_slug = Some(session.account_slug.clone());
        settings::save_general(&self.general_settings).await?;
        self.notify_settings_changed()?;

        self.refresh_ui_state();

        Ok(())
    }

    async fn update_telemetry_context(&mut self) -> Result<()> {
        let environment = self.api_url().to_string();
        let account_slug = self.auth.session().map(|s| s.account_slug.to_owned());

        if let Some(account_slug) = account_slug.clone() {
            Telemetry::set_account_slug(account_slug);
        }

        self.send_ipc(&service::ClientMsg::StartTelemetry {
            environment: environment.clone(),
            release: crate::RELEASE.to_string(),
            account_slug,
        })
        .await?;

        Ok(())
    }

    async fn handle_deep_link(&mut self, url: &Url) -> Result<()> {
        let auth_response =
            deep_link::parse_auth_callback(url).context("Couldn't parse scheme request")?;

        tracing::info!("Received deep link over IPC");

        // Uses `std::fs`
        let token = self
            .auth
            .handle_response(auth_response)
            .context("Couldn't handle auth response")?;

        self.update_telemetry_context().await?;
        self.start_session(token).await?;

        Ok(())
    }

    async fn handle_request(&mut self, req: ControllerRequest) -> Result<()> {
        use ControllerRequest::*;

        match req {
            ApplyAdvancedSettings(settings) => {
                self.log_filter_reloader
                    .reload(&settings.log_filter)
                    .context("Couldn't reload log filter")?;

                self.advanced_settings = *settings;

                // Save to disk
                settings::save_advanced(&self.advanced_settings).await?;

                // Tell tunnel about new log level
                self.send_ipc(&service::ClientMsg::ApplyLogFilter {
                    directives: self.advanced_settings.log_filter.clone(),
                })
                .await?;

                // Notify GUI that settings have changed
                self.notify_settings_changed()?;

                tracing::debug!("Applied new settings. Log level will take effect immediately.");

                // Refresh the menu in case the favorites were reset.
                self.refresh_ui_state();

                let _ = self.integration.show_notification("Settings saved", "")?;
            }
            ApplyGeneralSettings(settings) => {
                let account_slug = settings.account_slug.trim();

                self.apply_general_settings(GeneralSettings {
                    start_minimized: settings.start_minimized,
                    start_on_login: Some(settings.start_on_login),
                    connect_on_start: Some(settings.connect_on_start),
                    account_slug: (!account_slug.is_empty()).then_some(account_slug.to_owned()),
                    ..self.general_settings.clone()
                })
                .await?;
            }
            ResetGeneralSettings => {
                self.apply_general_settings(GeneralSettings {
                    start_minimized: true,
                    start_on_login: None,
                    connect_on_start: None,
                    account_slug: None,
                    ..self.general_settings.clone()
                })
                .await?;
            }
            ClearLogs(completion_tx) => {
                if self.clear_logs_callback.is_some() {
                    tracing::error!(
                        "Can't clear logs, we're already waiting on another log-clearing operation"
                    );
                }
                if let Err(error) = logging::clear_gui_logs().await {
                    tracing::error!("Failed to clear GUI logs: {error:#}");
                }
                self.send_ipc(&service::ClientMsg::ClearLogs).await?;
                self.clear_logs_callback = Some(completion_tx);
            }
            ExportLogs { path, stem } => logging::export_logs_to(path, stem)
                .await
                .context("Failed to export logs to zip")?,
            Fail(Failure::Crash) => {
                tracing::error!("Crashing on purpose");
                // SAFETY: Crashing is unsafe
                unsafe { sadness_generator::raise_segfault() }
            }
            Fail(Failure::Error) => Err(anyhow!("Test error"))?,
            Fail(Failure::Panic) => panic!("Test panic"),
            SignIn | SystemTrayMenu(system_tray::Event::SignIn) => {
                let auth_url = self.auth_url().clone();
                let account_slug = self.account_slug().map(|a| a.to_owned());

                let req = self
                    .auth
                    .start_sign_in()
                    .context("Couldn't start sign-in flow")?;

                let url = req.to_url(&auth_url, account_slug.as_deref());
                self.refresh_ui_state();
                self.integration
                    .open_url(url.expose_secret())
                    .context("Couldn't open auth page")?;
            }
            SystemTrayMenu(system_tray::Event::AddFavorite(resource_id)) => {
                self.general_settings.favorite_resources.insert(resource_id);
                self.refresh_favorite_resources().await?;
            }
            SystemTrayMenu(system_tray::Event::AdminPortal) => self
                .integration
                .open_url(self.auth_url())
                .context("Couldn't open auth page")?,
            SystemTrayMenu(system_tray::Event::Copy(s)) => arboard::Clipboard::new()
                .context("Couldn't access clipboard")?
                .set_text(s)
                .context("Couldn't copy resource URL or other text to clipboard")?,
            SystemTrayMenu(system_tray::Event::CancelSignIn) => match &self.status {
                Status::Disconnected | Status::WaitingForPortal => {
                    tracing::info!("Calling `sign_out` to cancel sign-in");
                    self.sign_out().await?;
                }
                Status::Quitting => tracing::error!("Can't cancel sign-in while already quitting"),
                Status::TunnelReady { .. } => tracing::error!(
                    "Can't cancel sign-in, the tunnel is already up. This is a logic error in the code."
                ),
                Status::WaitingForTunnel => {
                    tracing::debug!(
                        "Connlib is already raising the tunnel, calling `sign_out` anyway"
                    );
                    self.sign_out().await?;
                }
            },
            SystemTrayMenu(system_tray::Event::RemoveFavorite(resource_id)) => {
                self.general_settings
                    .favorite_resources
                    .remove(&resource_id);
                self.refresh_favorite_resources().await?;
            }
            SystemTrayMenu(system_tray::Event::EnableInternetResource) => {
                self.general_settings.internet_resource_enabled = Some(true);
                self.update_disabled_resources().await?;
            }
            SystemTrayMenu(system_tray::Event::DisableInternetResource) => {
                self.general_settings.internet_resource_enabled = Some(false);
                self.update_disabled_resources().await?;
            }
            SystemTrayMenu(system_tray::Event::ShowWindow(window)) => {
                match window {
                    system_tray::Window::About => self.integration.show_about_page()?,
                    system_tray::Window::Settings => self.integration.show_settings_page(
                        self.mdm_settings.clone(),
                        self.general_settings.clone(),
                        self.advanced_settings.clone(),
                    )?,
                };

                // When the About or Settings windows are hidden / shown, log the
                // run ID and uptime. This makes it easy to check client stability on
                // dev or test systems without parsing the whole log file.
                let uptime_info = self.uptime.info();
                tracing::debug!(
                    uptime_s = uptime_info.uptime.as_secs(),
                    run_id = uptime_info.run_id.to_string(),
                    "Uptime info"
                );
            }
            SignOut | SystemTrayMenu(system_tray::Event::SignOut) => {
                tracing::info!("User asked to sign out");
                self.sign_out().await?;
            }
            SystemTrayMenu(system_tray::Event::Url(url)) => self
                .integration
                .open_url(&url)
                .context("Couldn't open URL from system tray")?,
            SystemTrayMenu(system_tray::Event::Quit) => {
                tracing::info!("User clicked Quit in the menu");
                self.status = Status::Quitting;
                self.send_ipc(&service::ClientMsg::Disconnect).await?;
                self.refresh_ui_state();
            }
            UpdateNotificationClicked(download_url) => {
                tracing::info!("UpdateNotificationClicked in run_controller!");
                self.integration
                    .open_url(&download_url)
                    .context("Couldn't open update page")?;
            }
            UpdateState => {
                self.notify_settings_changed()?;

                let file_count = logging::count_logs().await?;
                self.integration.notify_logs_recounted(&file_count)?;

                self.refresh_ui_state();
            }
        }
        Ok(())
    }

    async fn apply_general_settings(&mut self, settings: GeneralSettings) -> Result<()> {
        self.general_settings = settings;

        settings::save_general(&self.general_settings).await?;

        gui::set_autostart(self.general_settings.start_on_login.is_some_and(|v| v)).await?;

        self.notify_settings_changed()?;
        let _ = self.integration.show_notification("Settings saved", "")?;

        Ok(())
    }

    async fn handle_service_ipc_msg(&mut self, msg: service::ServerMsg) -> Result<ControlFlow<()>> {
        match msg {
            service::ServerMsg::ClearedLogs(result) => {
                let Some(tx) = self.clear_logs_callback.take() else {
                    return Err(anyhow!(
                        "Can't handle `IpcClearedLogs` when there's no callback waiting for a `ClearLogs` result"
                    ));
                };
                tx.send(result)
                    .map_err(|_| anyhow!("Couldn't send `ClearLogs` result to Tauri task"))?;

                let file_count = logging::count_logs().await?;
                self.integration.notify_logs_recounted(&file_count)?;
            }
            service::ServerMsg::ConnectResult(result) => {
                self.handle_connect_result(result).await?;
            }
            service::ServerMsg::DisconnectedGracefully => {
                if let Status::Quitting = self.status {
                    return Ok(ControlFlow::Break(()));
                }
            }
            service::ServerMsg::OnDisconnect {
                error_msg,
                is_authentication_error,
            } => {
                self.sign_out().await?;
                if is_authentication_error {
                    tracing::info!(?error_msg, "Auth error");
                    let _ = self.integration.show_notification(
                        "Firezone disconnected",
                        "To access resources, sign in again.",
                    )?;
                } else {
                    tracing::error!("Connlib disconnected: {error_msg}");
                    native_dialog::MessageDialog::new()
                        .set_title("Firezone Error")
                        .set_text(&error_msg)
                        .set_type(native_dialog::MessageType::Error)
                        .show_alert()
                        .context("Couldn't show Disconnected alert")?;
                }
            }
            service::ServerMsg::OnUpdateResources(resources) => {
                if !self.status.needs_resource_updates() {
                    return Ok(ControlFlow::Continue(()));
                }

                // If this is the first time we receive resources, show the notification that we are connected.
                if let &Status::WaitingForTunnel = &self.status {
                    let _ = self.integration.show_notification(
                        "Firezone connected",
                        "You are now signed in and able to access resources.",
                    )?;
                }

                tracing::debug!(len = resources.len(), "Got new Resources");

                self.status = Status::TunnelReady { resources };

                self.refresh_ui_state();
                self.update_disabled_resources().await?;
            }
            service::ServerMsg::TerminatingGracefully => {
                tracing::info!("Tunnel service exited gracefully");
                self.integration
                    .set_tray_icon(system_tray::icon_terminating());
                let _ = self.integration.show_notification(
                    "Firezone disconnected",
                    "The Firezone Tunnel service was shut down, quitting GUI process.",
                )?;

                return Ok(ControlFlow::Break(()));
            }
            service::ServerMsg::Hello => {}
        }
        Ok(ControlFlow::Continue(()))
    }

    async fn handle_gui_ipc_msg(
        &mut self,
        maybe_msg: Option<Result<gui::ClientMsg>>,
    ) -> Result<()> {
        let client_msg = maybe_msg
            .context("No message received")?
            .context("Failed to read message")?;

        match client_msg {
            gui::ClientMsg::Deeplink(url) => match self.handle_deep_link(&url).await {
                Ok(()) => {}
                Err(error)
                    if error
                        .any_downcast_ref::<auth::Error>()
                        .is_some_and(|e| matches!(e, auth::Error::NoInflightRequest)) =>
                {
                    tracing::debug!("Ignoring deep-link; no local state");
                }
                Err(error) => {
                    tracing::error!("`handle_deep_link` failed: {error:#}");
                }
            },
            gui::ClientMsg::NewInstance => {
                let (_, session_view_model) = self.build_ui_state();

                self.integration.show_overview_page(&session_view_model)?;
            }
        }

        Ok(())
    }

    async fn handle_connect_result(&mut self, result: Result<(), String>) -> Result<()> {
        let Status::WaitingForPortal = &self.status else {
            tracing::debug!(current_state = ?self.status, "Ignoring `ConnectResult`");

            return Ok(());
        };

        match result {
            Ok(()) => {
                ran_before::set().await?;
                self.status = Status::WaitingForTunnel;
                self.refresh_ui_state();
                Ok(())
            }
            Err(error) => {
                // We log this here directly instead of forwarding it because errors hard-abort the event-loop and we still want to be able to export logs and stuff.
                // See <https://github.com/firezone/firezone/issues/6547>.
                tracing::error!("Failed to connect to Firezone: {error}");
                self.sign_out().await?;

                Ok(())
            }
        }
    }

    /// Set (or clear) update notification
    fn handle_update_notification(
        &mut self,
        notification: Option<updates::Notification>,
    ) -> Result<()> {
        let Some(notification) = notification else {
            self.release = None;
            self.refresh_ui_state();
            return Ok(());
        };

        let release = notification.release;
        self.release = Some(release.clone());
        self.refresh_ui_state();

        if notification.tell_user {
            #[cfg(target_os = "linux")]
            let body = ""; // TODO: Clickable notifications don't work on Linux yet.
            #[cfg(target_os = "macos")]
            let body = "";
            #[cfg(target_os = "windows")]
            let body = "Click here to download the new version";

            let NotificationHandle { on_click } = self.integration.show_notification(
                format!("Firezone {} available for download", release.version),
                body,
            )?;
            let ctrl_tx = self.ctrl_tx.clone();

            tokio::spawn(async move {
                if on_click.await.is_err() {
                    return;
                };

                let _ = ctrl_tx
                    .send(ControllerRequest::UpdateNotificationClicked(
                        release.download_url,
                    ))
                    .await;
            });
        }
        Ok(())
    }

    async fn update_disabled_resources(&mut self) -> Result<()> {
        settings::save_general(&self.general_settings).await?;

        let state = self.general_settings.internet_resource_enabled();

        self.send_ipc(&service::ClientMsg::SetInternetResourceState(state))
            .await?;
        self.refresh_ui_state();

        Ok(())
    }

    /// Saves the current settings (including favorites) to disk and refreshes the tray menu
    async fn refresh_favorite_resources(&mut self) -> Result<()> {
        settings::save_general(&self.general_settings).await?;
        self.refresh_ui_state();
        Ok(())
    }

    fn build_ui_state(&self) -> (system_tray::ConnlibState, SessionViewModel) {
        // TODO: Refactor `Controller` and the auth module so that "Are we logged in?"
        // doesn't require such complicated control flow to answer.
        if let Some(auth_session) = self.auth.session() {
            match &self.status {
                Status::Disconnected => {
                    // If we have an `auth_session` but no connlib session, we are most likely configured to
                    // _not_ auto-connect on startup. Thus, we treat this the same as being signed out.

                    (
                        system_tray::ConnlibState::SignedOut,
                        SessionViewModel::SignedOut,
                    )
                }
                Status::Quitting => (
                    system_tray::ConnlibState::Quitting,
                    SessionViewModel::Loading,
                ),
                Status::TunnelReady { resources } => (
                    system_tray::ConnlibState::SignedIn(system_tray::SignedIn {
                        actor_name: auth_session.actor_name.clone(),
                        favorite_resources: self.general_settings.favorite_resources.clone(),
                        internet_resource_enabled: self.general_settings.internet_resource_enabled,
                        resources: resources.clone(),
                    }),
                    SessionViewModel::SignedIn {
                        account_slug: auth_session.account_slug.clone(),
                        actor_name: auth_session.actor_name.clone(),
                    },
                ),
                Status::WaitingForPortal => (
                    system_tray::ConnlibState::WaitingForPortal,
                    SessionViewModel::Loading,
                ),
                Status::WaitingForTunnel => (
                    system_tray::ConnlibState::WaitingForTunnel,
                    SessionViewModel::Loading,
                ),
            }
        } else if self.auth.ongoing_request().is_some() {
            // Signing in, waiting on deep link callback
            (
                system_tray::ConnlibState::WaitingForBrowser,
                SessionViewModel::Loading,
            )
        } else {
            (
                system_tray::ConnlibState::SignedOut,
                SessionViewModel::SignedOut,
            )
        }
    }

    /// Refreshes our UI state (i.e. tray-menu and GUI).
    fn refresh_ui_state(&mut self) {
        let (connlib, session_view_model) = self.build_ui_state();

        self.integration.set_tray_menu(system_tray::AppState {
            connlib,
            release: self.release.clone(),
            hide_admin_portal_menu_item: self
                .mdm_settings
                .hide_admin_portal_menu_item
                .is_some_and(|hide| hide),
            support_url: self.mdm_settings.support_url.clone(),
        });
        if let Err(e) = self.integration.notify_session_changed(&session_view_model) {
            tracing::warn!("Failed to send notify session change: {e:#}")
        }
    }

    /// Deletes the auth token, stops connlib, and refreshes the tray menu
    async fn sign_out(&mut self) -> Result<()> {
        match self.status {
            Status::Quitting => return Ok(()),
            Status::Disconnected
            | Status::TunnelReady { .. }
            | Status::WaitingForPortal
            | Status::WaitingForTunnel => {}
        }
        self.auth.sign_out()?;
        self.status = Status::Disconnected;
        tracing::debug!("disconnecting connlib");
        // This is redundant if the token is expired, in that case
        // connlib already disconnected itself.
        self.send_ipc(&service::ClientMsg::Disconnect).await?;
        self.refresh_ui_state();
        Ok(())
    }

    async fn send_ipc(&mut self, msg: &service::ClientMsg) -> Result<()> {
        self.ipc_client
            .send(msg)
            .await
            .context("Failed to send IPC message")
    }

    fn notify_settings_changed(&mut self) -> Result<()> {
        self.integration.notify_settings_changed(
            self.mdm_settings.clone(),
            self.general_settings.clone(),
            self.advanced_settings.clone(),
        )?;

        Ok(())
    }

    fn auth_url(&self) -> &Url {
        self.mdm_settings
            .auth_url
            .as_ref()
            .unwrap_or(&self.advanced_settings.auth_url)
    }

    fn api_url(&self) -> &Url {
        self.mdm_settings
            .api_url
            .as_ref()
            .unwrap_or(&self.advanced_settings.api_url)
    }

    fn account_slug(&self) -> Option<&str> {
        self.mdm_settings
            .account_slug
            .as_deref()
            .or(self.general_settings.account_slug.as_deref())
    }

    fn connect_on_start(&self) -> Option<bool> {
        self.mdm_settings
            .connect_on_start
            .or(self.general_settings.connect_on_start)
    }
}

async fn receive_hello(ipc_rx: &mut ipc::ClientRead<service::ServerMsg>) -> Result<()> {
    const TIMEOUT: Duration = Duration::from_secs(5);

    let server_msg = tokio::time::timeout(TIMEOUT, ipc_rx.next())
        .await
        .with_context(|| {
            format!("Timeout while waiting for message from tunnel service for {TIMEOUT:?}")
        })?
        .context("No message received from tunnel service")?
        .context("Failed to receive message from tunnel service")?;

    if !matches!(server_msg, service::ServerMsg::Hello) {
        bail!("Expected `Hello` from tunnel service but got `{server_msg}`")
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex, MutexGuard};

    use uuid::Uuid;

    use super::*;

    #[tokio::test]
    async fn fails_without_receiving_hello() {
        let _guard = logging::test("debug");
        let mut test_controller = Controller::start_for_test();

        // Accept the IPC connection
        let (_tunnel_rx, _tunnel_tx) = test_controller.tunnel_service_ipc_accept().await;

        let start_error = tokio::time::timeout(Duration::from_secs(6), test_controller.join_handle)
            .await
            .expect("should not timeout")
            .unwrap()
            .unwrap_err();

        assert_eq!(
            start_error.to_string(),
            "Failed to receive hello: Timeout while waiting for message from tunnel service for 5s: deadline has elapsed"
        );
    }

    #[tokio::test]
    async fn launches_overview_page_on_startup() {
        let _guard = logging::test("debug");
        let mut test_controller = Controller::start_for_test();

        let (_tunnel_rx, mut tunnel_tx) = test_controller.tunnel_service_ipc_accept().await;
        tunnel_tx.send(&service::ServerMsg::Hello).await.unwrap();

        tokio::time::sleep(Duration::from_millis(500)).await;

        assert_eq!(test_controller.integration().shown_overview_page.len(), 1);
    }

    #[tokio::test]
    async fn shows_page_when_2nd_instance_launches() {
        let _guard = logging::test("debug");
        let mut test_controller = Controller::start_for_test();

        let (_tunnel_rx, mut tunnel_tx) = test_controller.tunnel_service_ipc_accept().await;
        tunnel_tx.send(&service::ServerMsg::Hello).await.unwrap();

        let (mut gui_rx, mut gui_tx) = test_controller.gui_ipc_connect().await;
        gui_tx.send(&gui::ClientMsg::NewInstance).await.unwrap();
        let response = gui_rx.next().await.unwrap().unwrap();

        tokio::time::sleep(Duration::from_millis(500)).await;

        assert_eq!(test_controller.integration().shown_overview_page.len(), 2);
        assert_eq!(response, gui::ServerMsg::Ack)
    }

    #[expect(dead_code, reason = "It is a test.")]
    struct TestController {
        join_handle: tokio::task::JoinHandle<Result<()>>,
        tunnel_server: ipc::Server,
        ctrl_tx: mpsc::Sender<ControllerRequest>,
        updates_tx: mpsc::Sender<Option<updates::Notification>>,
        integration: Arc<Mutex<TestIntegration>>,
        gui_id: &'static str,
    }

    impl TestController {
        async fn tunnel_service_ipc_accept(
            &mut self,
        ) -> (
            ipc::ServerRead<service::ClientMsg>,
            ipc::ServerWrite<service::ServerMsg>,
        ) {
            self.tunnel_server
                .next_client_split::<service::ClientMsg, service::ServerMsg>()
                .await
                .unwrap()
        }

        async fn gui_ipc_connect(
            &mut self,
        ) -> (
            ipc::ClientRead<gui::ServerMsg>,
            ipc::ClientWrite<gui::ClientMsg>,
        ) {
            ipc::connect(
                SocketId::Test(self.gui_id),
                ipc::ConnectOptions { num_attempts: 1 },
            )
            .await
            .unwrap()
        }

        fn integration(&self) -> MutexGuard<'_, TestIntegration> {
            self.integration.lock().unwrap()
        }
    }

    #[derive(Default)]
    struct TestIntegration {
        sessions: Vec<SessionViewModel>,
        mdm_settings: Vec<MdmSettings>,
        general_settings: Vec<GeneralSettings>,
        advanced_settings: Vec<AdvancedSettings>,
        file_counts: Vec<FileCount>,
        opened_urls: Vec<String>,
        tray_icons: Vec<system_tray::Icon>,
        tray_states: Vec<system_tray::AppState>,
        notifications: Vec<(String, String, futures::channel::oneshot::Sender<()>)>,
        window_visibilities: Vec<bool>,
        shown_overview_page: Vec<SessionViewModel>,
        shown_settings_page: Vec<(MdmSettings, GeneralSettings, AdvancedSettings)>,
        shown_about_page: Vec<()>,
    }

    impl GuiIntegration for Arc<Mutex<TestIntegration>> {
        fn notify_session_changed(&self, session: &SessionViewModel) -> Result<()> {
            self.lock().unwrap().sessions.push(session.clone());

            Ok(())
        }

        fn notify_settings_changed(
            &self,
            mdm_settings: MdmSettings,
            general_settings: GeneralSettings,
            advanced_settings: AdvancedSettings,
        ) -> Result<()> {
            let mut guard = self.lock().unwrap();

            guard.mdm_settings.push(mdm_settings);
            guard.general_settings.push(general_settings);
            guard.advanced_settings.push(advanced_settings);

            Ok(())
        }

        fn notify_logs_recounted(&self, file_count: &FileCount) -> Result<()> {
            self.lock().unwrap().file_counts.push(file_count.clone());

            Ok(())
        }

        fn open_url<P: AsRef<str>>(&self, url: P) -> Result<()> {
            self.lock()
                .unwrap()
                .opened_urls
                .push(url.as_ref().to_owned());

            Ok(())
        }

        fn set_tray_icon(&mut self, icon: system_tray::Icon) {
            self.lock().unwrap().tray_icons.push(icon);
        }

        fn set_tray_menu(&mut self, app_state: system_tray::AppState) {
            self.lock().unwrap().tray_states.push(app_state);
        }

        fn show_notification(
            &self,
            title: impl Into<String>,
            body: impl Into<String>,
        ) -> Result<NotificationHandle> {
            let (tx, rx) = futures::channel::oneshot::channel();

            self.lock()
                .unwrap()
                .notifications
                .push((title.into(), body.into(), tx));

            Ok(NotificationHandle { on_click: rx })
        }

        fn set_window_visible(&self, visible: bool) -> Result<()> {
            self.lock().unwrap().window_visibilities.push(visible);

            Ok(())
        }

        fn show_overview_page(&self, session: &SessionViewModel) -> Result<()> {
            self.lock()
                .unwrap()
                .shown_overview_page
                .push(session.clone());

            Ok(())
        }

        fn show_settings_page(
            &self,
            mdm_settings: MdmSettings,
            general_settings: GeneralSettings,
            settings: AdvancedSettings,
        ) -> Result<()> {
            self.lock().unwrap().shown_settings_page.push((
                mdm_settings,
                general_settings,
                settings,
            ));

            Ok(())
        }

        fn show_about_page(&self) -> Result<()> {
            self.lock().unwrap().shown_about_page.push(());

            Ok(())
        }
    }

    impl Controller<Arc<Mutex<TestIntegration>>> {
        fn start_for_test() -> TestController {
            let id = Uuid::new_v4().to_string().leak();

            // Leaking memory here is fine because we are in a test and the process is terminated at the end.
            let tunnel_id = format!("{id}_tunnel").leak();
            let gui_id = format!("{id}_gui").leak();

            let tunnel_ipc_server = ipc::Server::new(SocketId::Test(tunnel_id)).unwrap();
            let gui_ipc_server = ipc::Server::new(SocketId::Test(gui_id)).unwrap();

            let (ctrl_tx, ctrl_rx) = mpsc::channel(16);
            let (updates_tx, updates_rx) = mpsc::channel(16);
            let (_, log_filter_reloader) = logging::try_filter::<()>("debug").unwrap();
            let integration = Arc::new(Mutex::new(TestIntegration::default()));

            let join_handle = tokio::spawn(Self::start(
                SocketId::Test(tunnel_id),
                integration.clone(),
                ctrl_tx.clone(),
                ctrl_rx,
                GeneralSettings::default(),
                MdmSettings::default(),
                AdvancedSettings::default(),
                log_filter_reloader,
                updates_rx,
                gui_ipc_server,
            ));

            TestController {
                join_handle,
                integration,
                tunnel_server: tunnel_ipc_server,
                ctrl_tx,
                updates_tx,
                gui_id,
            }
        }
    }
}
