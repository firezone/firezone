//! The Tauri-based GUI Client for Windows and Linux
//!
//! Most of this Client is stubbed out with panics on macOS.
//! The real macOS Client is in `swift/apple`

use crate::client::{
    self, about, deep_link, ipc, logging,
    settings::{self, AdvancedSettings},
    updates::Release,
    Failure,
};
use anyhow::{anyhow, bail, Context, Result};
use firezone_bin_shared::{new_dns_notifier, new_network_notifier};
use firezone_headless_client::{
    IpcClientMsg::{self, SetDisabledResources},
    IpcServerMsg, IpcServiceError, LogFilterReloader,
};
use secrecy::{ExposeSecret, SecretString};
use std::{
    path::PathBuf,
    str::FromStr,
    time::{Duration, Instant},
};
use system_tray::Event as TrayMenuEvent;
use tauri::{Manager, SystemTrayEvent};
use tokio::sync::{mpsc, oneshot};
use tracing::instrument;
use url::Url;

use ControllerRequest as Req;

mod errors;
mod ran_before;
pub(crate) mod system_tray;

#[cfg(target_os = "linux")]
#[path = "gui/os_linux.rs"]
#[allow(clippy::unnecessary_wraps)]
mod os;

// Stub only
#[cfg(target_os = "macos")]
#[path = "gui/os_macos.rs"]
#[allow(clippy::unnecessary_wraps)]
mod os;

#[cfg(target_os = "windows")]
#[path = "gui/os_windows.rs"]
#[allow(clippy::unnecessary_wraps)]
mod os;

use connlib_shared::callbacks::ResourceDescription;
pub(crate) use errors::{show_error_dialog, Error};
pub(crate) use os::set_autostart;

pub(crate) type CtlrTx = mpsc::Sender<ControllerRequest>;

/// All managed state that we might need to access from odd places like Tauri commands.
///
/// Note that this never gets Dropped because of
/// <https://github.com/tauri-apps/tauri/issues/8631>
pub(crate) struct Managed {
    pub ctlr_tx: CtlrTx,
    pub inject_faults: bool,
}

/// Runs the Tauri GUI and returns on exit or unrecoverable error
///
/// Still uses `thiserror` so we can catch the deep_link `CantListen` error
#[instrument(skip_all)]
pub(crate) fn run(
    cli: client::Cli,
    advanced_settings: settings::AdvancedSettings,
    reloader: LogFilterReloader,
) -> Result<(), Error> {
    // Need to keep this alive so crashes will be handled. Dropping detaches it.
    let _crash_handler = match client::crash_handling::attach_handler() {
        Ok(x) => Some(x),
        Err(error) => {
            // TODO: None of these logs are actually written yet
            // <https://github.com/firezone/firezone/issues/3211>
            tracing::warn!(?error, "Did not set up crash handler");
            None
        }
    };

    // Needed for the deep link server
    let rt = tokio::runtime::Runtime::new().context("Couldn't start Tokio runtime")?;
    let _guard = rt.enter();

    // Make sure we're single-instance
    // We register our deep links to call the `open-deep-link` subcommand,
    // so if we're at this point, we know we've been launched manually
    let deep_link_server = rt.block_on(async { deep_link::Server::new().await })?;

    let (ctlr_tx, ctlr_rx) = mpsc::channel(5);

    let managed = Managed {
        ctlr_tx: ctlr_tx.clone(),
        inject_faults: cli.inject_faults,
    };

    tracing::info!("Setting up Tauri app instance...");
    let (setup_result_tx, mut setup_result_rx) =
        tokio::sync::oneshot::channel::<Result<(), Error>>();
    let app = tauri::Builder::default()
        .manage(managed)
        .on_window_event(|event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event.event() {
                // Keep the frontend running but just hide this webview
                // Per https://tauri.app/v1/guides/features/system-tray/#preventing-the-app-from-closing
                // Closing the window fully seems to deallocate it or something.

                event.window().hide().unwrap();
                api.prevent_close();
            }
        })
        .invoke_handler(tauri::generate_handler![
            about::get_cargo_version,
            about::get_git_version,
            logging::clear_logs,
            logging::count_logs,
            logging::export_logs,
            settings::apply_advanced_settings,
            settings::reset_advanced_settings,
            settings::get_advanced_settings,
            crate::client::welcome::sign_in,
        ])
        .system_tray(system_tray::loading())
        .on_system_tray_event(|app, event| {
            if let SystemTrayEvent::MenuItemClick { id, .. } = event {
                tracing::debug!(?id, "SystemTrayEvent::MenuItemClick");
                let event = match serde_json::from_str::<TrayMenuEvent>(&id) {
                    Ok(x) => x,
                    Err(e) => {
                        tracing::error!("{e}");
                        return;
                    }
                };
                match handle_system_tray_event(app, event) {
                    Ok(_) => {}
                    Err(e) => tracing::error!("{e}"),
                }
            }
        })
        .setup(move |app| {
            tracing::info!("Entered Tauri's `setup`");

            let setup_inner = move || {
                // Check for updates
                let ctlr_tx_clone = ctlr_tx.clone();
                tokio::spawn(async move {
                    if let Err(error) = crate::client::updates::checker_task(ctlr_tx_clone, cli.debug_update_check).await
                    {
                        tracing::error!(?error, "Error in updates::checker_task");
                    }
                });

                if let Some(client::Cmd::SmokeTest) = &cli.command {
                    let ctlr_tx = ctlr_tx.clone();
                    tokio::spawn(async move {
                        if let Err(error) = smoke_test(ctlr_tx).await {
                            tracing::error!(?error, "Error during smoke test, crashing on purpose so a dev can see our stacktraces");
                            unsafe { sadness_generator::raise_segfault() }
                        }
                    });
                }

                tracing::debug!(cli.no_deep_links);
                if !cli.no_deep_links {
                    // The single-instance check is done, so register our exe
                    // to handle deep links
                    deep_link::register().context("Failed to register deep link handler")?;
                    tokio::spawn(accept_deep_links(deep_link_server, ctlr_tx.clone()));
                }

                if let Some(failure) = cli.fail_on_purpose() {
                    let ctlr_tx = ctlr_tx.clone();
                    tokio::spawn(async move {
                        let delay = 5;
                        tracing::info!(
                            "Will crash / error / panic on purpose in {delay} seconds to test error handling."
                        );
                        tokio::time::sleep(Duration::from_secs(delay)).await;
                        tracing::info!("Crashing / erroring / panicking on purpose");
                        ctlr_tx.send(ControllerRequest::Fail(failure)).await?;
                        Ok::<_, anyhow::Error>(())
                    });
                }

                assert_eq!(
                    firezone_bin_shared::BUNDLE_ID,
                    app.handle().config().tauri.bundle.identifier,
                    "BUNDLE_ID should match bundle ID in tauri.conf.json"
                );

                let app_handle = app.handle();
                let _ctlr_task = tokio::spawn(async move {
                    let app_handle_2 = app_handle.clone();
                    // Spawn two nested Tasks so the outer can catch panics from the inner
                    let task = tokio::spawn(async move {
                        run_controller(
                            app_handle_2,
                            ctlr_tx,
                            ctlr_rx,
                            advanced_settings,
                            reloader,
                        )
                        .await
                    });

                    // See <https://github.com/tauri-apps/tauri/issues/8631>
                    // This should be the ONLY place we call `app.exit` or `app_handle.exit`,
                    // because it exits the entire process without dropping anything.
                    //
                    // This seems to be a platform limitation that Tauri is unable to hide
                    // from us. It was the source of much consternation at time of writing.

                    let exit_code = match task.await {
                        Err(error) => {
                            tracing::error!(?error, "run_controller panicked");
                            1
                        }
                        Ok(Err(error)) => {
                            tracing::error!(?error, "run_controller returned an error");
                            errors::show_error_dialog(&error).unwrap();
                            1
                        }
                        Ok(Ok(_)) => 0,
                    };

                    tracing::info!(?exit_code);
                    app_handle.exit(exit_code);
                });
                Ok(())
            };

            setup_result_tx.send(setup_inner()).expect("should be able to send setup result");

            Ok(())
        });
    tracing::debug!("Building Tauri app...");
    let app = app.build(tauri::generate_context!());

    setup_result_rx
        .try_recv()
        .context("couldn't receive result of setup")??;

    let app = match app {
        Ok(x) => x,
        Err(error) => {
            tracing::error!(?error, "Failed to build Tauri app instance");
            #[allow(clippy::wildcard_enum_match_arm)]
            match error {
                tauri::Error::Runtime(tauri_runtime::Error::CreateWebview(_)) => {
                    return Err(Error::WebViewNotInstalled);
                }
                error => Err(anyhow::Error::from(error).context("Tauri error"))?,
            }
        }
    };

    app.run(|_app_handle, event| {
        if let tauri::RunEvent::ExitRequested { api, .. } = event {
            // Don't exit if we close our main window
            // https://tauri.app/v1/guides/features/system-tray/#preventing-the-app-from-closing

            api.prevent_exit();
        }
    });
    Ok(())
}

#[cfg(not(debug_assertions))]
async fn smoke_test(_: CtlrTx) -> Result<()> {
    bail!("Smoke test is not built for release binaries.");
}

/// Runs a smoke test and then asks Controller to exit gracefully
///
/// You can purposely fail this test by deleting the exported zip file during
/// the 10-second sleep.
#[cfg(debug_assertions)]
async fn smoke_test(ctlr_tx: CtlrTx) -> Result<()> {
    let delay = 10;
    tracing::info!("Will quit on purpose in {delay} seconds as part of the smoke test.");
    let quit_time = tokio::time::Instant::now() + Duration::from_secs(delay);

    // Test log exporting
    let path = PathBuf::from("smoke_test_log_export.zip");

    let stem = "connlib-smoke-test".into();
    match tokio::fs::remove_file(&path).await {
        Ok(()) => {}
        Err(error) => {
            if error.kind() != std::io::ErrorKind::NotFound {
                bail!("Error while removing old zip file")
            }
        }
    }
    ctlr_tx
        .send(ControllerRequest::ExportLogs {
            path: path.clone(),
            stem,
        })
        .await
        .context("Failed to send `ExportLogs` request")?;
    let (tx, rx) = oneshot::channel();
    ctlr_tx
        .send(ControllerRequest::ClearLogs(tx))
        .await
        .context("Failed to send `ClearLogs` request")?;
    rx.await
        .context("Failed to await `ClearLogs` result")?
        .map_err(|s| anyhow!(s))
        .context("`ClearLogs` failed")?;

    // Give the app some time to export the zip and reach steady state
    tokio::time::sleep_until(quit_time).await;

    // Write the settings so we can check the path for those
    settings::save(&settings::AdvancedSettings::default()).await?;

    // Check results of tests
    let zip_len = tokio::fs::metadata(&path)
        .await
        .context("Failed to get zip file metadata")?
        .len();
    if zip_len <= 22 {
        bail!("Exported log zip just has the file header");
    }
    tokio::fs::remove_file(&path)
        .await
        .context("Failed to remove zip file")?;
    tracing::info!(?path, ?zip_len, "Exported log zip looks okay");

    // Check that settings file and at least one log file were written
    anyhow::ensure!(tokio::fs::try_exists(settings::advanced_settings_path()?).await?);

    tracing::info!("Quitting on purpose because of `smoke-test` subcommand");
    ctlr_tx
        .send(ControllerRequest::SystemTrayMenu(TrayMenuEvent::Quit))
        .await
        .context("Failed to send Quit request")?;

    Ok::<_, anyhow::Error>(())
}

/// Worker task to accept deep links from a named pipe forever
///
/// * `server` An initial named pipe server to consume before making new servers. This lets us also use the named pipe to enforce single-instance
async fn accept_deep_links(mut server: deep_link::Server, ctlr_tx: CtlrTx) -> Result<()> {
    loop {
        match server.accept().await {
            Ok(bytes) => {
                let url = SecretString::from_str(
                    std::str::from_utf8(bytes.expose_secret())
                        .context("Incoming deep link was not valid UTF-8")?,
                )
                .context("Impossible: can't wrap String into SecretString")?;
                // Ignore errors from this, it would only happen if the app is shutting down, otherwise we would wait
                ctlr_tx
                    .send(ControllerRequest::SchemeRequest(url))
                    .await
                    .ok();
            }
            Err(error) => tracing::error!(?error, "error while accepting deep link"),
        }
        // We re-create the named pipe server every time we get a link, because of an oddity in the Windows API.
        server = deep_link::Server::new().await?;
    }
}

fn handle_system_tray_event(app: &tauri::AppHandle, event: TrayMenuEvent) -> Result<()> {
    app.try_state::<Managed>()
        .context("can't get Managed struct from Tauri")?
        .ctlr_tx
        .blocking_send(ControllerRequest::SystemTrayMenu(event))?;
    Ok(())
}

// Allow dead code because `UpdateNotificationClicked` doesn't work on Linux yet
#[allow(dead_code)]
pub(crate) enum ControllerRequest {
    /// The GUI wants us to use these settings in-memory, they've already been saved to disk
    ApplySettings(AdvancedSettings),
    /// Clear the GUI's logs and await the IPC service to clear its logs
    ClearLogs(oneshot::Sender<Result<(), String>>),
    /// The same as the arguments to `client::logging::export_logs_to`
    ExportLogs {
        path: PathBuf,
        stem: PathBuf,
    },
    Fail(Failure),
    GetAdvancedSettings(oneshot::Sender<AdvancedSettings>),
    Ipc(IpcServerMsg),
    IpcClosed,
    IpcReadFailed(anyhow::Error),
    SchemeRequest(SecretString),
    SignIn,
    SystemTrayMenu(TrayMenuEvent),
    /// Set (or clear) update notification
    SetUpdateNotification(Option<crate::client::updates::Notification>),
    UpdateNotificationClicked(Url),
}

enum Status {
    /// Firezone is disconnected.
    Disconnected,
    /// At least one connection request has failed, due to failing to reach the Portal, and we are waiting for a network change before we try again
    RetryingConnection {
        /// The token to log in to the Portal, for retrying the connection request.
        token: SecretString,
    },
    /// Firezone is ready to use.
    TunnelReady { resources: Vec<ResourceDescription> },
    /// Firezone is signing in to the Portal.
    WaitingForPortal {
        /// The instant when we sent our most recent connect request.
        start_instant: Instant,
        /// The token to log in to the Portal, in case we need to retry the connection request.
        token: SecretString,
    },
    /// Firezone has connected to the Portal and is raising the tunnel.
    WaitingForTunnel {
        /// The instant when we sent our most recent connect request.
        start_instant: Instant,
    },
}

impl Default for Status {
    fn default() -> Self {
        Self::Disconnected
    }
}

impl Status {
    /// Returns true if we want to hear about DNS and network changes.
    fn needs_network_changes(&self) -> bool {
        match self {
            Status::Disconnected | Status::RetryingConnection { .. } => false,
            Status::TunnelReady { .. }
            | Status::WaitingForPortal { .. }
            | Status::WaitingForTunnel { .. } => true,
        }
    }
}

struct Controller {
    /// Debugging-only settings like API URL, auth URL, log filter
    advanced_settings: AdvancedSettings,
    app: tauri::AppHandle,
    // Sign-in state with the portal / deep links
    auth: client::auth::Auth,
    clear_logs_callback: Option<oneshot::Sender<Result<(), String>>>,
    ctlr_tx: CtlrTx,
    ipc_client: ipc::Client,
    log_filter_reloader: LogFilterReloader,
    /// A release that's ready to download
    release: Option<Release>,
    status: Status,
    tray: system_tray::Tray,
    uptime: client::uptime::Tracker,
}

impl Controller {
    async fn start_session(&mut self, token: SecretString) -> Result<(), Error> {
        match self.status {
            Status::Disconnected | Status::RetryingConnection { .. } => {}
            Status::TunnelReady { .. } => Err(anyhow!(
                "Can't connect to Firezone, we're already connected."
            ))?,
            Status::WaitingForPortal { .. } | Status::WaitingForTunnel { .. } => Err(anyhow!(
                "Can't connect to Firezone, we're already connecting."
            ))?,
        }

        let api_url = self.advanced_settings.api_url.clone();
        tracing::info!(api_url = api_url.to_string(), "Starting connlib...");

        // Count the start instant from before we connect
        let start_instant = Instant::now();
        self.ipc_client
            .connect_to_firezone(api_url.as_str(), token.expose_secret().clone().into())
            .await?;
        // Change the status after we begin connecting
        self.status = Status::WaitingForPortal {
            start_instant,
            token,
        };
        self.refresh_system_tray_menu()?;
        Ok(())
    }

    async fn handle_deep_link(&mut self, url: &SecretString) -> Result<(), Error> {
        let auth_response =
            client::deep_link::parse_auth_callback(url).context("Couldn't parse scheme request")?;

        tracing::info!("Received deep link over IPC");
        // Uses `std::fs`
        let token = self
            .auth
            .handle_response(auth_response)
            .context("Couldn't handle auth response")?;
        self.start_session(token).await?;
        Ok(())
    }

    async fn handle_request(&mut self, req: ControllerRequest) -> Result<(), Error> {
        match req {
            Req::ApplySettings(settings) => {
                let filter = firezone_logging::try_filter(&self.advanced_settings.log_filter)
                        .context("Couldn't parse new log filter directives")?;
                self.advanced_settings = settings;
                self.log_filter_reloader
                    .reload(filter)
                    .context("Couldn't reload log filter")?;
                self.ipc_client.send_msg(&IpcClientMsg::ReloadLogFilter).await?;
                tracing::debug!(
                    "Applied new settings. Log level will take effect immediately."
                );
                // Refresh the menu in case the favorites were reset.
                self.refresh_system_tray_menu()?;
            }
            Req::ClearLogs(completion_tx) => {
                if self.clear_logs_callback.is_some() {
                    tracing::error!("Can't clear logs, we're already waiting on another log-clearing operation");
                }
                if let Err(error) = logging::clear_gui_logs().await {
                    tracing::error!(?error, "Failed to clear GUI logs");
                }
                self.ipc_client.send_msg(&IpcClientMsg::ClearLogs).await?;
                self.clear_logs_callback = Some(completion_tx);
            }
            Req::ExportLogs { path, stem } => logging::export_logs_to(path, stem)
                .await
                .context("Failed to export logs to zip")?,
            Req::Fail(_) => Err(anyhow!(
                "Impossible error: `Fail` should be handled before this"
            ))?,
            Req::GetAdvancedSettings(tx) => {
                tx.send(self.advanced_settings.clone()).ok();
            }
            Req::Ipc(msg) => self.handle_ipc(msg).await?,
            Req::IpcReadFailed(error) => {
                // IPC errors are always fatal
                tracing::error!(?error, "IPC read failure");
                Err(Error::IpcRead)?
            }
            Req::IpcClosed => Err(Error::IpcClosed)?,
            Req::SchemeRequest(url) => {
                if let Err(error) = self.handle_deep_link(&url).await {
                    tracing::error!(?error, "`handle_deep_link` failed");
                }
            }
            Req::SetUpdateNotification(notification) => {
                let Some(notification) = notification else {
                    self.release = None;
                    self.refresh_system_tray_menu()?;
                    return Ok(());
                };

                let release = notification.release;
                self.release = Some(release.clone());
                self.refresh_system_tray_menu()?;

                if notification.tell_user {
                    let title = format!("Firezone {} available for download", release.version);

                    // We don't need to route through the controller here either, we could
                    // use the `open` crate directly instead of Tauri's wrapper
                    // `tauri::api::shell::open`
                    os::show_update_notification(self.ctlr_tx.clone(), &title, release.download_url)?;
                }
            }
            Req::SignIn | Req::SystemTrayMenu(TrayMenuEvent::SignIn) => {
                if let Some(req) = self
                    .auth
                    .start_sign_in()
                    .context("Couldn't start sign-in flow")?
                {
                    let url = req.to_url(&self.advanced_settings.auth_base_url);
                    self.refresh_system_tray_menu()?;
                    tauri::api::shell::open(&self.app.shell_scope(), url.expose_secret(), None)
                        .context("Couldn't open auth page")?;
                    self.app
                        .get_window("welcome")
                        .context("Couldn't get handle to Welcome window")?
                        .hide()
                        .context("Couldn't hide Welcome window")?;
                }
            }
            Req::SystemTrayMenu(TrayMenuEvent::AddFavorite(resource_id)) => {
                self.advanced_settings.favorite_resources.insert(resource_id);
                self.refresh_favorite_resources().await?;
            },
            Req::SystemTrayMenu(TrayMenuEvent::AdminPortal) => tauri::api::shell::open(
                &self.app.shell_scope(),
                &self.advanced_settings.auth_base_url,
                None,
            )
            .context("Couldn't open auth page")?,
            Req::SystemTrayMenu(TrayMenuEvent::Copy(s)) => arboard::Clipboard::new()
                .context("Couldn't access clipboard")?
                .set_text(s)
                .context("Couldn't copy resource URL or other text to clipboard")?,
            Req::SystemTrayMenu(TrayMenuEvent::CancelSignIn) => {
                match &self.status {
                    Status::Disconnected | Status::RetryingConnection { .. } | Status::WaitingForPortal { .. } => {
                        tracing::info!("Calling `sign_out` to cancel sign-in");
                        self.sign_out().await?;
                    }
                    Status::TunnelReady{..} => tracing::error!("Can't cancel sign-in, the tunnel is already up. This is a logic error in the code."),
                    Status::WaitingForTunnel { .. } => {
                        tracing::warn!(
                            "Connlib is already raising the tunnel, calling `sign_out` anyway"
                        );
                        self.sign_out().await?;
                    }
                }
            }
            Req::SystemTrayMenu(TrayMenuEvent::RemoveFavorite(resource_id)) => {
                self.advanced_settings.favorite_resources.remove(&resource_id);
                self.refresh_favorite_resources().await?;
            }
            Req::SystemTrayMenu(TrayMenuEvent::RetryPortalConnection) => self.try_retry_connection().await?,
            Req::SystemTrayMenu(TrayMenuEvent::EnableResource(resource_id)) => {
                self.advanced_settings.disabled_resources.remove(&resource_id);
                self.update_disabled_resources().await?;
            }
            Req::SystemTrayMenu(TrayMenuEvent::DisableResource(resource_id)) => {
                self.advanced_settings.disabled_resources.insert(resource_id);
                self.update_disabled_resources().await?;
            }
            Req::SystemTrayMenu(TrayMenuEvent::ShowWindow(window)) => {
                self.show_window(window)?;
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
            Req::SystemTrayMenu(TrayMenuEvent::SignOut) => {
                tracing::info!("User asked to sign out");
                self.sign_out().await?;
            }
            Req::SystemTrayMenu(TrayMenuEvent::Url(url)) => {
                tauri::api::shell::open(&self.app.shell_scope(), url, None)
                    .context("Couldn't open URL from system tray")?
            }
            Req::SystemTrayMenu(TrayMenuEvent::Quit) => Err(anyhow!(
                "Impossible error: `Quit` should be handled before this"
            ))?,
            Req::UpdateNotificationClicked(download_url) => {
                tracing::info!("UpdateNotificationClicked in run_controller!");
                tauri::api::shell::open(&self.app.shell_scope(), download_url, None)
                    .context("Couldn't open update page")?;
            }
        }
        Ok(())
    }

    async fn handle_ipc(&mut self, msg: IpcServerMsg) -> Result<(), Error> {
        match msg {
            IpcServerMsg::ClearedLogs(result) => {
                let Some(tx) = self.clear_logs_callback.take() else {
                    return Err(Error::Other(anyhow!("Can't handle `IpcClearedLogs` when there's no callback waiting for a `ClearLogs` result")));
                };
                tx.send(result).map_err(|_| {
                    Error::Other(anyhow!("Couldn't send `ClearLogs` result to Tauri task"))
                })?;
                Ok(())
            }
            IpcServerMsg::ConnectResult(result) => self.handle_connect_result(result).await,
            IpcServerMsg::OnDisconnect {
                error_msg,
                is_authentication_error,
            } => {
                self.sign_out().await?;
                if is_authentication_error {
                    tracing::info!(?error_msg, "Auth error");
                    os::show_notification(
                        "Firezone disconnected",
                        "To access resources, sign in again.",
                    )?;
                } else {
                    tracing::error!(?error_msg, "Disconnected");
                    native_dialog::MessageDialog::new()
                        .set_title("Firezone Error")
                        .set_text(&error_msg)
                        .set_type(native_dialog::MessageType::Error)
                        .show_alert()
                        .context("Couldn't show Disconnected alert")?;
                }
                Ok(())
            }
            IpcServerMsg::OnUpdateResources(resources) => {
                tracing::debug!(len = resources.len(), "Got new Resources");
                self.status = Status::TunnelReady { resources };
                if let Err(error) = self.refresh_system_tray_menu() {
                    tracing::error!(?error, "Failed to refresh menu");
                }

                self.update_disabled_resources().await?;

                Ok(())
            }
            IpcServerMsg::TerminatingGracefully => {
                tracing::info!("Caught TerminatingGracefully");
                self.tray.set_icon(system_tray::Icon::terminating()).ok();
                Err(Error::IpcServiceTerminating)
            }
            IpcServerMsg::TunnelReady => {
                if self.auth.session().is_none() {
                    // This could maybe happen if the user cancels the sign-in
                    // before it completes. This is because the state machine
                    // between the GUI, the IPC service, and connlib isn't  perfectly synced.
                    tracing::error!("Got `UpdateResources` while signed out");
                    return Ok(());
                }
                if let Status::WaitingForTunnel { start_instant } =
                    std::mem::replace(&mut self.status, Status::TunnelReady { resources: vec![] })
                {
                    tracing::info!(elapsed = ?start_instant.elapsed(), "Tunnel ready");
                    os::show_notification(
                        "Firezone connected",
                        "You are now signed in and able to access resources.",
                    )?;
                }
                if let Err(error) = self.refresh_system_tray_menu() {
                    tracing::error!(?error, "Failed to refresh menu");
                }

                Ok(())
            }
        }
    }

    async fn handle_connect_result(
        &mut self,
        result: Result<(), IpcServiceError>,
    ) -> Result<(), Error> {
        let (start_instant, token) = match &self.status {
            Status::Disconnected
            | Status::RetryingConnection { .. }
            | Status::TunnelReady { .. }
            | Status::WaitingForTunnel { .. } => {
                tracing::error!("Impossible logic error, received `ConnectResult` when we weren't waiting on the Portal connection.");
                return Ok(());
            }
            Status::WaitingForPortal {
                start_instant,
                token,
            } => (*start_instant, token.expose_secret().clone().into()),
        };

        match result {
            Ok(()) => {
                ran_before::set().await?;
                self.status = Status::WaitingForTunnel { start_instant };
                if let Err(error) = self.refresh_system_tray_menu() {
                    tracing::error!(?error, "Failed to refresh menu");
                }
                Ok(())
            }
            Err(IpcServiceError::PortalConnection(error)) => {
                tracing::warn!(
                    ?error,
                    "Failed to connect to Firezone Portal, will try again when the network changes"
                );
                self.status = Status::RetryingConnection { token };
                if let Err(error) = self.refresh_system_tray_menu() {
                    tracing::error!(?error, "Failed to refresh menu");
                }
                Ok(())
            }
            Err(error) => {
                tracing::error!(?error, "Failed to connect to Firezone");
                Err(Error::Other(anyhow!(
                    "Failed to connect to Firezone for non-Portal-related reason"
                )))
            }
        }
    }

    async fn update_disabled_resources(&mut self) -> Result<()> {
        settings::save(&self.advanced_settings).await?;

        let Status::TunnelReady { resources } = &self.status else {
            bail!("Tunnel is not ready");
        };

        let disabled_resources = resources
            .iter()
            .filter_map(|r| r.can_be_disabled().then_some(r.id()))
            .filter(|id| self.advanced_settings.disabled_resources.contains(id))
            .collect();

        self.ipc_client
            .send_msg(&SetDisabledResources(disabled_resources))
            .await?;
        self.refresh_system_tray_menu()?;

        Ok(())
    }

    /// Saves the current settings (including favorites) to disk and refreshes the tray menu
    async fn refresh_favorite_resources(&mut self) -> Result<()> {
        settings::save(&self.advanced_settings).await?;
        self.refresh_system_tray_menu()?;
        Ok(())
    }

    /// Builds a new system tray menu and applies it to the app
    fn refresh_system_tray_menu(&mut self) -> Result<()> {
        // TODO: Refactor `Controller` and the auth module so that "Are we logged in?"
        // doesn't require such complicated control flow to answer.
        let connlib = if let Some(auth_session) = self.auth.session() {
            match &self.status {
                Status::Disconnected => {
                    tracing::error!("We have an auth session but no connlib session");
                    system_tray::ConnlibState::SignedOut
                }
                Status::RetryingConnection { .. } => system_tray::ConnlibState::RetryingConnection,
                Status::TunnelReady { resources } => {
                    system_tray::ConnlibState::SignedIn(system_tray::SignedIn {
                        actor_name: &auth_session.actor_name,
                        favorite_resources: &self.advanced_settings.favorite_resources,
                        disabled_resources: &self.advanced_settings.disabled_resources,
                        resources,
                    })
                }
                Status::WaitingForPortal { .. } => system_tray::ConnlibState::WaitingForPortal,
                Status::WaitingForTunnel { .. } => system_tray::ConnlibState::WaitingForTunnel,
            }
        } else if self.auth.ongoing_request().is_ok() {
            // Signing in, waiting on deep link callback
            system_tray::ConnlibState::WaitingForBrowser
        } else {
            system_tray::ConnlibState::SignedOut
        };
        self.tray.update(system_tray::AppState {
            connlib,
            release: self.release.clone(),
        })?;
        Ok(())
    }

    /// If we're in the `RetryingConnection` state, use the token to retry the Portal connection
    async fn try_retry_connection(&mut self) -> Result<()> {
        let token = match &self.status {
            Status::Disconnected
            | Status::TunnelReady { .. }
            | Status::WaitingForPortal { .. }
            | Status::WaitingForTunnel { .. } => return Ok(()),
            Status::RetryingConnection { token } => token,
        };
        tracing::debug!("Retrying Portal connection...");
        self.start_session(token.expose_secret().clone().into())
            .await?;
        Ok(())
    }

    /// Deletes the auth token, stops connlib, and refreshes the tray menu
    async fn sign_out(&mut self) -> Result<()> {
        self.auth.sign_out()?;
        self.status = Status::Disconnected;
        tracing::debug!("disconnecting connlib");
        // This is redundant if the token is expired, in that case
        // connlib already disconnected itself.
        self.ipc_client.disconnect_from_firezone().await?;
        self.refresh_system_tray_menu()?;
        Ok(())
    }

    fn show_window(&self, window: system_tray::Window) -> Result<()> {
        let id = match window {
            system_tray::Window::About => "about",
            system_tray::Window::Settings => "settings",
        };

        let win = self
            .app
            .get_window(id)
            .context("Couldn't get handle to `{id}` window")?;

        // Needed to bring shown windows to the front
        // `request_user_attention` and `set_focus` don't work, at least on Linux
        win.hide()?;
        // Needed to show windows that are completely hidden
        win.show()?;
        Ok(())
    }
}

// TODO: Move this into `impl Controller`
async fn run_controller(
    app: tauri::AppHandle,
    ctlr_tx: CtlrTx,
    mut rx: mpsc::Receiver<ControllerRequest>,
    advanced_settings: AdvancedSettings,
    log_filter_reloader: LogFilterReloader,
) -> Result<(), Error> {
    tracing::info!("Entered `run_controller`");
    let ipc_client = ipc::Client::new(ctlr_tx.clone()).await?;
    let tray = system_tray::Tray::new(app.tray_handle());
    let mut controller = Controller {
        advanced_settings,
        app: app.clone(),
        auth: client::auth::Auth::new()?,
        clear_logs_callback: None,
        ctlr_tx,
        ipc_client,
        log_filter_reloader,
        release: None,
        status: Default::default(),
        tray,
        uptime: Default::default(),
    };

    if let Some(token) = controller
        .auth
        .token()
        .context("Failed to load token from disk during app start")?
    {
        controller.start_session(token).await?;
    } else {
        tracing::info!("No token / actor_name on disk, starting in signed-out state");
        controller.refresh_system_tray_menu()?;
    }

    if !ran_before::get().await? {
        let win = app
            .get_window("welcome")
            .context("Couldn't get handle to Welcome window")?;
        win.show().context("Couldn't show Welcome window")?;
    }

    let tokio_handle = tokio::runtime::Handle::current();
    let dns_control_method = Default::default();

    let mut dns_notifier = new_dns_notifier(tokio_handle.clone(), dns_control_method).await?;
    let mut network_notifier =
        new_network_notifier(tokio_handle.clone(), dns_control_method).await?;
    drop(tokio_handle);

    loop {
        // TODO: Add `ControllerRequest::NetworkChange` and `DnsChange` and replace
        // `tokio::select!` with a `poll_*` function
        tokio::select! {
            result = network_notifier.notified() => {
                result?;
                if controller.status.needs_network_changes() {
                    tracing::debug!("Internet up/down changed, calling `Session::reset`");
                    controller.ipc_client.reset().await?
                }
                controller.try_retry_connection().await?
            },
            result = dns_notifier.notified() => {
                result?;
                if controller.status.needs_network_changes() {
                    let resolvers = firezone_headless_client::dns_control::system_resolvers_for_gui()?;
                    tracing::debug!(?resolvers, "New DNS resolvers, calling `Session::set_dns`");
                    controller.ipc_client.set_dns(resolvers).await?;
                }
                controller.try_retry_connection().await?
            },
            req = rx.recv() => {
                let Some(req) = req else {
                    break;
                };

                #[allow(clippy::wildcard_enum_match_arm)]
                match req {
                    // SAFETY: Crashing is unsafe
                    Req::Fail(Failure::Crash) => {
                        tracing::error!("Crashing on purpose");
                        unsafe { sadness_generator::raise_segfault() }
                    },
                    Req::Fail(Failure::Error) => Err(anyhow!("Test error"))?,
                    Req::Fail(Failure::Panic) => panic!("Test panic"),
                    Req::SystemTrayMenu(TrayMenuEvent::Quit) => {
                        tracing::info!("User clicked Quit in the menu");
                        break
                    }
                    // TODO: Should we really skip cleanup if a request fails?
                    req => controller.handle_request(req).await?,
                }
            },
        }
        // Code down here may not run because the `select` sometimes `continue`s.
    }

    if let Err(error) = network_notifier.close() {
        tracing::error!(?error, "com_worker");
    }
    if let Err(error) = controller.ipc_client.disconnect_from_ipc().await {
        tracing::error!(?error, "ipc_client");
    }

    // Last chance to do any drops / cleanup before the process crashes.

    Ok(())
}
