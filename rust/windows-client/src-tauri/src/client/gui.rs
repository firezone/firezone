//! The Tauri GUI for Windows
//! This is not checked or compiled on other platforms.

// TODO: `git grep` for unwraps before 1.0, especially this gui module <https://github.com/firezone/firezone/issues/3521>

use crate::client::{
    self, about, deep_link, logging, network_changes,
    settings::{self, AdvancedSettings},
};
use anyhow::{anyhow, bail, Context, Result};
use arc_swap::ArcSwap;
use connlib_client_shared::{file_logger, ResourceDescription};
use connlib_shared::{messages::ResourceId, windows::BUNDLE_ID};
use secrecy::{ExposeSecret, SecretString};
use std::{net::IpAddr, path::PathBuf, str::FromStr, sync::Arc, time::Duration};
use system_tray_menu::Event as TrayMenuEvent;
use tauri::{api::notification::Notification, Manager, SystemTray, SystemTrayEvent};
use tokio::sync::{mpsc, oneshot, Notify};
use ControllerRequest as Req;

mod system_tray_menu;

/// The Windows client doesn't use platform APIs to detect network connectivity changes,
/// so we rely on connlib to do so. We have valid use cases for headless Windows clients
/// (IoT devices, point-of-sale devices, etc), so try to reconnect for 30 days if there's
/// been a partition.
const MAX_PARTITION_TIME: Duration = Duration::from_secs(60 * 60 * 24 * 30);

pub(crate) type CtlrTx = mpsc::Sender<ControllerRequest>;

/// All managed state that we might need to access from odd places like Tauri commands.
///
/// Note that this never gets Dropped because of
/// <https://github.com/tauri-apps/tauri/issues/8631>
pub(crate) struct Managed {
    pub ctlr_tx: CtlrTx,
    pub inject_faults: bool,
}

impl Managed {
    #[cfg(debug_assertions)]
    /// In debug mode, if `--inject-faults` is passed, sleep for `millis` milliseconds
    pub async fn fault_msleep(&self, millis: u64) {
        if self.inject_faults {
            tokio::time::sleep(std::time::Duration::from_millis(millis)).await;
        }
    }

    #[cfg(not(debug_assertions))]
    /// Does nothing in release mode
    pub async fn fault_msleep(&self, _millis: u64) {}
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum Error {
    #[error("Deep-link module error: {0}")]
    DeepLink(#[from] deep_link::Error),
    #[error("Can't show log filter error dialog: {0}")]
    LogFilterErrorDialog(native_dialog::Error),
    #[error("Logging module error: {0}")]
    Logging(#[from] logging::Error),
    #[error(transparent)]
    Tauri(#[from] tauri::Error),
    #[error("tokio::runtime::Runtime::new failed: {0}")]
    TokioRuntimeNew(std::io::Error),

    // `client.rs` provides a more user-friendly message when showing the error dialog box
    #[error("WebViewNotInstalled")]
    WebViewNotInstalled,
}

/// Runs the Tauri GUI and returns on exit or unrecoverable error
pub(crate) fn run(cli: client::Cli) -> Result<(), Error> {
    let advanced_settings = settings::load_advanced_settings().unwrap_or_default();

    // If the log filter is unparsable, show an error and use the default
    // Fixes <https://github.com/firezone/firezone/issues/3452>
    let advanced_settings =
        match tracing_subscriber::EnvFilter::from_str(&advanced_settings.log_filter) {
            Ok(_) => advanced_settings,
            Err(_) => {
                native_dialog::MessageDialog::new()
                    .set_title("Log filter error")
                    .set_text(
                        "The custom log filter is not parsable. Using the default log filter.",
                    )
                    .set_type(native_dialog::MessageType::Error)
                    .show_alert()
                    .map_err(Error::LogFilterErrorDialog)?;

                AdvancedSettings {
                    log_filter: AdvancedSettings::default().log_filter,
                    ..advanced_settings
                }
            }
        };

    // Start logging
    // TODO: After <https://github.com/firezone/firezone/pull/3430> lands, try using an
    // Arc to keep the file logger alive even if Tauri bails out
    let logging_handles = client::logging::setup(&advanced_settings.log_filter)?;
    tracing::info!("started log");
    tracing::info!("GIT_VERSION = {}", crate::client::GIT_VERSION);

    let client::Cli {
        command: _,
        crash_on_purpose,
        inject_faults,
    } = cli;

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
    let rt = tokio::runtime::Runtime::new().map_err(Error::TokioRuntimeNew)?;
    let _guard = rt.enter();

    if crash_on_purpose {
        tokio::spawn(async {
            let delay = 10;
            tracing::info!("Will crash on purpose in {delay} seconds to test crash handling.");
            tokio::time::sleep(std::time::Duration::from_secs(delay)).await;
            tracing::info!("Crashing on purpose because of `--crash-on-purpose` flag");

            // SAFETY: Crashing is unsafe
            unsafe { sadness_generator::raise_segfault() }
        });
    }

    let (ctlr_tx, ctlr_rx) = mpsc::channel(5);
    let notify_controller = Arc::new(Notify::new());

    // Make sure we're single-instance
    // We register our deep links to call the `open-deep-link` subcommand,
    // so if we're at this point, we know we've been launched manually
    let server = deep_link::Server::new()?;

    // We know now we're the only instance on the computer, so register our exe
    // to handle deep links
    deep_link::register()?;
    tokio::spawn(accept_deep_links(server, ctlr_tx.clone()));

    let managed = Managed {
        ctlr_tx: ctlr_tx.clone(),
        inject_faults,
    };

    let tray = SystemTray::new().with_menu(system_tray_menu::signed_out());

    let app = tauri::Builder::default()
        .manage(managed)
        .on_window_event(|event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event.event() {
                // Keep the frontend running but just hide this webview
                // Per https://tauri.app/v1/guides/features/system-tray/#preventing-the-app-from-closing

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
        ])
        .system_tray(tray)
        .on_system_tray_event(|app, event| {
            if let SystemTrayEvent::MenuItemClick { id, .. } = event {
                let event = match TrayMenuEvent::from_str(&id) {
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
            assert_eq!(
                BUNDLE_ID,
                app.handle().config().tauri.bundle.identifier,
                "BUNDLE_ID should match bundle ID in tauri.conf.json"
            );

            let app_handle = app.handle();
            let _ctlr_task = tokio::spawn(async move {
                let result = run_controller(
                    app_handle.clone(),
                    ctlr_tx,
                    ctlr_rx,
                    logging_handles,
                    advanced_settings,
                    notify_controller,
                )
                .await;

                // See <https://github.com/tauri-apps/tauri/issues/8631>
                // This should be the ONLY place we call `app.exit` or `app_handle.exit`,
                // because it exits the entire process without dropping anything.
                //
                // This seems to be a platform limitation that Tauri is unable to hide
                // from us. It was the source of much consternation at time of writing.

                if let Err(e) = result {
                    tracing::error!("run_controller returned an error: {e:#?}");
                    app_handle.exit(1);
                } else {
                    tracing::debug!("GUI controller task exited cleanly");
                    app_handle.exit(0);
                }
            });

            Ok(())
        })
        .build(tauri::generate_context!());

    let app = match app {
        Ok(x) => x,
        Err(error) => {
            tracing::error!(?error, "Failed to build Tauri app instance");
            match error {
                tauri::Error::Runtime(tauri_runtime::Error::CreateWebview(_)) => {
                    return Err(Error::WebViewNotInstalled);
                }
                error => Err(error)?,
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

/// Worker task to accept deep links from a named pipe forever
///
/// * `server` An initial named pipe server to consume before making new servers. This lets us also use the named pipe to enforce single-instance
async fn accept_deep_links(mut server: deep_link::Server, ctlr_tx: CtlrTx) -> Result<()> {
    loop {
        if let Ok(url) = server.accept().await {
            ctlr_tx
                .send(ControllerRequest::SchemeRequest(url))
                .await
                .ok();
        }
        // We re-create the named pipe server every time we get a link, because of an oddity in the Windows API.
        server = deep_link::Server::new()?;
    }
}

fn handle_system_tray_event(app: &tauri::AppHandle, event: TrayMenuEvent) -> Result<()> {
    app.try_state::<Managed>()
        .context("can't get Managed struct from Tauri")?
        .ctlr_tx
        .blocking_send(ControllerRequest::SystemTrayMenu(event))?;
    Ok(())
}

pub(crate) enum ControllerRequest {
    Disconnected,
    DisconnectedTokenExpired,
    ExportLogs { path: PathBuf, stem: PathBuf },
    GetAdvancedSettings(oneshot::Sender<AdvancedSettings>),
    SchemeRequest(url::Url),
    SystemTrayMenu(TrayMenuEvent),
    TunnelReady,
}

#[derive(Clone)]
struct CallbackHandler {
    logger: file_logger::Handle,
    notify_controller: Arc<Notify>,
    ctlr_tx: CtlrTx,
    resources: Arc<ArcSwap<Vec<ResourceDescription>>>,
}

#[derive(thiserror::Error, Debug)]
enum CallbackError {
    #[error("system DNS resolver problem: {0}")]
    Resolvers(#[from] client::resolvers::Error),
    #[error("can't send to controller task: {0}")]
    SendError(#[from] mpsc::error::TrySendError<ControllerRequest>),
}

// Callbacks must all be non-blocking
impl connlib_client_shared::Callbacks for CallbackHandler {
    type Error = CallbackError;

    fn on_disconnect(
        &self,
        error: Option<&connlib_client_shared::Error>,
    ) -> Result<(), Self::Error> {
        tracing::debug!("on_disconnect {error:?}");
        self.ctlr_tx.try_send(match error {
            Some(connlib_client_shared::Error::ClosedByPortal) => {
                // TODO: this can happen for other reasons
                ControllerRequest::DisconnectedTokenExpired
            }
            _ => ControllerRequest::Disconnected,
        })?;
        Ok(())
    }

    fn on_tunnel_ready(&self) -> Result<(), Self::Error> {
        tracing::info!("on_tunnel_ready");
        self.ctlr_tx.try_send(ControllerRequest::TunnelReady)?;
        Ok(())
    }

    fn on_update_resources(&self, resources: Vec<ResourceDescription>) -> Result<(), Self::Error> {
        tracing::info!("on_update_resources");
        self.resources.store(resources.into());
        self.notify_controller.notify_one();
        Ok(())
    }

    fn get_system_default_resolvers(&self) -> Result<Option<Vec<IpAddr>>, Self::Error> {
        Ok(Some(client::resolvers::get()?))
    }

    fn roll_log_file(&self) -> Option<PathBuf> {
        self.logger.roll_to_new_file().unwrap_or_else(|e| {
            tracing::debug!("Failed to roll over to new file: {e}");

            None
        })
    }
}

struct Controller {
    /// Debugging-only settings like API URL, auth URL, log filter
    advanced_settings: AdvancedSettings,
    app: tauri::AppHandle,
    // Sign-in state with the portal / deep links
    auth: client::auth::Auth,
    ctlr_tx: CtlrTx,
    /// connlib session for the currently signed-in user, if there is one
    session: Option<Session>,
    /// The UUIDv4 device ID persisted to disk
    /// Sent verbatim to Session::connect
    device_id: String,
    logging_handles: client::logging::Handles,
    /// Tells us when to wake up and look for a new resource list. Tokio docs say that memory reads and writes are synchronized when notifying, so we don't need an extra mutex on the resources.
    notify_controller: Arc<Notify>,
    tunnel_ready: bool,
}

/// Everything related to a signed-in user session
struct Session {
    callback_handler: CallbackHandler,
    connlib: connlib_client_shared::Session<CallbackHandler>,
}

impl Controller {
    async fn new(
        app: tauri::AppHandle,
        ctlr_tx: CtlrTx,
        logging_handles: client::logging::Handles,
        advanced_settings: AdvancedSettings,
        notify_controller: Arc<Notify>,
    ) -> Result<Self> {
        let device_id = client::device_id::device_id(&app.config().tauri.bundle.identifier).await?;

        let mut this = Self {
            advanced_settings,
            app,
            auth: client::auth::Auth::new()?,
            ctlr_tx,
            session: None,
            device_id,
            logging_handles,
            notify_controller,
            tunnel_ready: false,
        };

        if let Some(token) = this.auth.token()? {
            // Connect immediately if we reloaded the token
            if let Err(e) = this.start_session(token) {
                tracing::error!("couldn't restart session on app start: {e:#?}");
            }
        }

        Ok(this)
    }

    // TODO: Figure out how re-starting sessions automatically will work
    /// Pre-req: the auth module must be signed in
    fn start_session(&mut self, token: SecretString) -> Result<()> {
        if self.session.is_some() {
            bail!("can't start session, we're already in a session");
        }

        let callback_handler = CallbackHandler {
            ctlr_tx: self.ctlr_tx.clone(),
            logger: self.logging_handles.logger.clone(),
            notify_controller: Arc::clone(&self.notify_controller),
            resources: Default::default(),
        };

        let connlib = connlib_client_shared::Session::connect(
            self.advanced_settings.api_url.clone(),
            token,
            self.device_id.clone(),
            None, // `get_host_name` over in connlib gets the system's name automatically
            None,
            callback_handler.clone(),
            Some(MAX_PARTITION_TIME),
        )?;

        self.session = Some(Session {
            callback_handler,
            connlib,
        });
        self.refresh_system_tray_menu()?;

        Ok(())
    }

    fn copy_resource(&self, id: &str) -> Result<()> {
        let Some(session) = &self.session else {
            bail!("app is signed out");
        };
        let resources = session.callback_handler.resources.load();
        let id = ResourceId::from_str(id)?;
        let Some(res) = resources.iter().find(|r| r.id() == id) else {
            bail!("resource ID is not in the list");
        };
        let mut clipboard = arboard::Clipboard::new()?;
        // TODO: Make this a method on `ResourceDescription`
        match res {
            ResourceDescription::Dns(x) => clipboard.set_text(&x.address)?,
            ResourceDescription::Cidr(x) => clipboard.set_text(&x.address.to_string())?,
        }
        Ok(())
    }

    async fn handle_deep_link(&mut self, url: &url::Url) -> Result<()> {
        let auth_response =
            client::deep_link::parse_auth_callback(url).context("Couldn't parse scheme request")?;

        let token = self.auth.handle_response(auth_response)?;
        self.start_session(token)
            .context("Couldn't start connlib session")?;
        Ok(())
    }

    /// Returns a new system tray menu
    fn build_system_tray_menu(&self) -> tauri::SystemTrayMenu {
        // TODO: Refactor this and the auth module so that "Are we logged in"
        // doesn't require such complicated control flow to answer.
        // TODO: Show some "Waiting for portal..." state if we got the deep link but
        // haven't got `on_tunnel_ready` yet.
        if let Some(auth_session) = self.auth.session() {
            if let Some(connlib_session) = &self.session {
                if self.tunnel_ready {
                    // Signed in, tunnel ready
                    let resources = connlib_session.callback_handler.resources.load();
                    system_tray_menu::signed_in(&auth_session.actor_name, &resources)
                } else {
                    // Signed in, raising tunnel
                    system_tray_menu::signing_in()
                }
            } else {
                tracing::error!("We have an auth session but no connlib session");
                system_tray_menu::signed_out()
            }
        } else if self.auth.ongoing_request().is_ok() {
            // Signing in, waiting on deep link callback
            system_tray_menu::signing_in()
        } else {
            system_tray_menu::signed_out()
        }
    }

    /// Builds a new system tray menu and applies it to the app
    fn refresh_system_tray_menu(&self) -> Result<()> {
        Ok(self
            .app
            .tray_handle()
            .set_menu(self.build_system_tray_menu())?)
    }

    /// Deletes the auth token, stops connlib, and refreshes the tray menu
    fn sign_out(&mut self) -> Result<()> {
        self.auth.sign_out()?;
        self.tunnel_ready = false;
        if let Some(mut session) = self.session.take() {
            tracing::debug!("disconnecting connlib");
            // This is redundant if the token is expired, in that case
            // connlib already disconnected itself.
            session.connlib.disconnect(None);
        } else {
            // Might just be because we got a double sign-out or
            // the user canceled the sign-in or something innocent.
            tracing::warn!("tried to sign out but there's no session");
        }
        self.refresh_system_tray_menu()?;
        Ok(())
    }

    fn toggle_window(&self, window: system_tray_menu::Window) -> Result<()> {
        let id = match window {
            system_tray_menu::Window::About => "about",
            system_tray_menu::Window::Settings => "settings",
        };

        let win = self
            .app
            .get_window(id)
            .ok_or_else(|| anyhow!("getting handle to `{id}` window"))?;

        if win.is_visible()? {
            // If we close the window here, we can't re-open it, we'd have to fully re-create it. Not needed for MVP - We agreed 100 MB is fine for the GUI client.
            win.hide()?;
        } else {
            win.show()?;
        }
        Ok(())
    }
}

// TODO: Move this into `impl Controller`
async fn run_controller(
    app: tauri::AppHandle,
    ctlr_tx: CtlrTx,
    mut rx: mpsc::Receiver<ControllerRequest>,
    logging_handles: client::logging::Handles,
    advanced_settings: AdvancedSettings,
    notify_controller: Arc<Notify>,
) -> Result<()> {
    let mut controller = Controller::new(
        app.clone(),
        ctlr_tx,
        logging_handles,
        advanced_settings,
        notify_controller,
    )
    .await
    .context("couldn't create Controller")?;

    let mut have_internet = network_changes::check_internet()?;
    tracing::debug!(?have_internet);

    let mut com_worker = network_changes::Worker::new()?;

    loop {
        tokio::select! {
            () = controller.notify_controller.notified() => if let Err(e) = controller.refresh_system_tray_menu() {
                tracing::error!("couldn't reload resource list: {e:#?}");
            },
            () = com_worker.notified() => {
                let new_have_internet = network_changes::check_internet()?;
                if new_have_internet != have_internet {
                    have_internet = new_have_internet;
                    // TODO: Stop / start / restart connlib as needed here
                    tracing::debug!(?have_internet);
                }
            },
            req = rx.recv() => {
                let Some(req) = req else {
                    break;
                };
                match req {
                    Req::Disconnected => {
                        tracing::debug!("connlib disconnected, tearing down Session");
                        controller.tunnel_ready = false;
                        if let Some(mut session) = controller.session.take() {
                            tracing::debug!("disconnecting connlib");
                            // This is probably redundant since connlib shuts itself down if it's disconnected.
                            session.connlib.disconnect(None);
                        }
                        controller.refresh_system_tray_menu()?;
                    }
                    Req::DisconnectedTokenExpired => {
                        tracing::info!("Token expired");
                        controller.sign_out()?;
                        show_notification("Firezone disconnected", "To access resources, sign in again.")?;
                    }
                    Req::ExportLogs{path, stem} => logging::export_logs_to(path, stem).await?,
                    Req::GetAdvancedSettings(tx) => {
                        tx.send(controller.advanced_settings.clone()).ok();
                    }
                    Req::SchemeRequest(url) => if let Err(e) = controller.handle_deep_link(&url).await {
                        tracing::error!("couldn't handle deep link: {e:#?}");
                    }
                    Req::SystemTrayMenu(TrayMenuEvent::ToggleWindow(window)) => controller.toggle_window(window)?,
                    Req::SystemTrayMenu(TrayMenuEvent::CancelSignIn | TrayMenuEvent::SignOut) => {
                        tracing::info!("User signed out or canceled sign-in");
                        controller.sign_out()?;
                    }
                    Req::SystemTrayMenu(TrayMenuEvent::Resource { id }) => if let Err(e) = controller.copy_resource(&id) {
                        tracing::error!("couldn't copy resource to clipboard: {e:#?}");
                    }
                    Req::SystemTrayMenu(TrayMenuEvent::SignIn) => {
                        if let Some(req) = controller.auth.start_sign_in()? {
                            let url = req.to_url(&controller.advanced_settings.auth_base_url);
                            controller.refresh_system_tray_menu()?;
                            tauri::api::shell::open(
                                &app.shell_scope(),
                                &url.expose_secret().inner,
                                None,
                            )?;
                        }
                    }
                    Req::SystemTrayMenu(TrayMenuEvent::Quit) => break,
                    Req::TunnelReady => {
                        controller.tunnel_ready = true;
                        controller.refresh_system_tray_menu()?;

                        show_notification("Firezone connected", "You are now signed in and able to access resources.")?;
                    },
                }
            }
        }
    }

    if let Err(error) = com_worker.close() {
        tracing::error!(?error, "com_worker");
    }

    // Last chance to do any drops / cleanup before the process crashes.

    Ok(())
}

/// Show a notification in the bottom right of the screen
///
/// May say "Windows Powershell" and have the wrong icon in dev mode
/// See <https://github.com/tauri-apps/tauri/issues/3700>
fn show_notification(title: &str, body: &str) -> Result<()> {
    Notification::new(BUNDLE_ID)
        .title(title)
        .body(body)
        .show()?;
    Ok(())
}
