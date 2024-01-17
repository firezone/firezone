//! The Tauri GUI for Windows
//! This is not checked or compiled on other platforms.

// TODO: `git grep` for unwraps before 1.0, especially this gui module

use crate::client::{self, deep_link, network_changes, AppLocalDataDir};
use anyhow::{anyhow, bail, Context, Result};
use arc_swap::ArcSwap;
use client::{
    logging,
    settings::{self, AdvancedSettings},
};
use connlib_client_shared::{file_logger, ResourceDescription};
use connlib_shared::messages::ResourceId;
use secrecy::{ExposeSecret, SecretString};
use std::{net::IpAddr, path::PathBuf, str::FromStr, sync::Arc, time::Duration};
use system_tray_menu::Event as TrayMenuEvent;
use tauri::{api::notification::Notification, Manager, SystemTray, SystemTrayEvent};
use tokio::sync::{mpsc, oneshot, Notify};

use ControllerRequest as Req;

mod system_tray_menu;

pub(crate) type CtlrTx = mpsc::Sender<ControllerRequest>;

pub(crate) fn app_local_data_dir(app: &tauri::AppHandle) -> Result<AppLocalDataDir> {
    let path = app
        .path_resolver()
        .app_local_data_dir()
        .ok_or_else(|| anyhow!("getting app_local_data_dir"))?;
    Ok(AppLocalDataDir(path))
}

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

// TODO: We're supposed to get this from Tauri, but I'd need to move some things around first
const TAURI_ID: &str = "dev.firezone.client";

/// Runs the Tauri GUI and returns on exit or unrecoverable error
pub(crate) fn run(params: client::GuiParams) -> Result<()> {
    let client::GuiParams {
        flag_elevated,
        inject_faults,
    } = params;

    let rt = tokio::runtime::Runtime::new()?;
    let _guard = rt.enter();

    // Make sure we're single-instance
    // We register our deep links to call the `open-deep-link` subcommand,
    // so if we're at this point, we know we've been launched manually
    let server = deep_link::Server::new(TAURI_ID)?;

    // We know now we're the only instance on the computer, so register our exe
    // to handle deep links
    deep_link::register(TAURI_ID)?;

    let (ctlr_tx, ctlr_rx) = mpsc::channel(5);
    let notify_controller = Arc::new(Notify::new());

    tokio::spawn(accept_deep_links(server, ctlr_tx.clone()));

    let managed = Managed {
        ctlr_tx: ctlr_tx.clone(),
        inject_faults,
    };

    let tray = SystemTray::new().with_menu(system_tray_menu::signed_out());

    tauri::Builder::default()
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
            logging::clear_logs,
            logging::export_logs,
            logging::start_stop_log_counting,
            settings::apply_advanced_settings,
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
            // Change to data dir so the file logger will write there and not in System32 if we're launching from an app link
            let cwd = app_local_data_dir(&app.handle())?.0.join("data");
            std::fs::create_dir_all(&cwd)?;
            std::env::set_current_dir(&cwd)?;

            let advanced_settings = tokio::runtime::Handle::current()
                .block_on(settings::load_advanced_settings(&app.handle()))
                .unwrap_or_default();

            // Set up logger
            // It's hard to set it up before Tauri's setup, because Tauri knows where all the config and data go in AppData and I don't want to replicate their logic.
            let logging_handles = client::logging::setup(&advanced_settings.log_filter)?;
            tracing::info!("started log");
            tracing::info!("GIT_VERSION = {}", crate::client::GIT_VERSION);
            // I checked this on my dev system to make sure Powershell is doing what I expect and passing the argument back to us after relaunch
            tracing::debug!("flag_elevated: {flag_elevated}");

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
        .build(tauri::generate_context!())?
        .run(|_app_handle, event| {
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
        server = deep_link::Server::new(TAURI_ID)?;
    }
}

fn handle_system_tray_event(app: &tauri::AppHandle, event: TrayMenuEvent) -> Result<()> {
    let ctlr_tx = &app
        .try_state::<Managed>()
        .ok_or_else(|| anyhow!("can't get Managed struct from Tauri"))?
        .ctlr_tx;

    match event {
        TrayMenuEvent::About => {
            let win = app
                .get_window("about")
                .ok_or_else(|| anyhow!("getting handle to About window"))?;

            if win.is_visible()? {
                win.hide()?;
            } else {
                win.show()?;
            }
        }
        TrayMenuEvent::Resource { id } => {
            ctlr_tx.blocking_send(ControllerRequest::CopyResource(id))?
        }
        TrayMenuEvent::Settings => {
            let win = app
                .get_window("settings")
                .ok_or_else(|| anyhow!("getting handle to Settings window"))?;

            if win.is_visible()? {
                // If we close the window here, we can't re-open it, we'd have to fully re-create it. Not needed for MVP - We agreed 100 MB is fine for the GUI client.
                win.hide()?;
            } else {
                win.show()?;
            }
        }
        TrayMenuEvent::SignIn => ctlr_tx.blocking_send(ControllerRequest::SignIn)?,
        TrayMenuEvent::SignOut => ctlr_tx.blocking_send(ControllerRequest::SignOut)?,
        TrayMenuEvent::Quit => ctlr_tx.blocking_send(ControllerRequest::Quit)?,
    }
    Ok(())
}

pub(crate) enum ControllerRequest {
    CopyResource(String),
    Disconnected,
    DisconnectedTokenExpired,
    ExportLogs { path: PathBuf, stem: PathBuf },
    GetAdvancedSettings(oneshot::Sender<AdvancedSettings>),
    Quit,
    SchemeRequest(url::Url),
    SignIn,
    StartStopLogCounting(bool),
    SignOut,
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
            Some(connlib_client_shared::Error::TokenExpired) => {
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
    log_counting_task: Option<tokio::task::JoinHandle<Result<()>>>,
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
            log_counting_task: None,
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
            None, // TODO: Send device name here (windows computer name)
            None,
            callback_handler.clone(),
            Duration::from_secs(5 * 60),
        )?;

        self.session = Some(Session {
            callback_handler,
            connlib,
        });

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
        let Some(auth_response) = client::deep_link::parse_auth_callback(url) else {
            // TODO: `bail` is redundant here, just do `.context("")?;` since it's `anyhow`
            bail!("couldn't parse scheme request");
        };

        let token = self.auth.handle_response(auth_response)?;
        if let Err(e) = self.start_session(token) {
            // TODO: Replace `bail` with `context` here too
            bail!("couldn't start session: {e:#?}");
        }
        Ok(())
    }

    /// Returns a new system tray menu
    fn build_system_tray_menu(&self) -> tauri::SystemTrayMenu {
        // TODO: Refactor this and the auth module so that "Are we logged in"
        // doesn't require such complicated control flow to answer.
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
}

// TODO: After PR #2960 lands, move some of this into `impl Controller`
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

    let mut have_internet = network_changes::Listener::check_internet()?;
    tracing::debug!(?have_internet);

    let com_worker = network_changes::Worker::new()?;

    loop {
        tokio::select! {
            () = controller.notify_controller.notified() => if let Err(e) = controller.refresh_system_tray_menu() {
                tracing::error!("couldn't reload resource list: {e:#?}");
            },
            () = com_worker.notified() => {
                let new_have_internet = network_changes::Listener::check_internet()?;
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
                    Req::CopyResource(id) => if let Err(e) = controller.copy_resource(&id) {
                        tracing::error!("couldn't copy resource to clipboard: {e:#?}");
                    }
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
                    Req::DisconnectedTokenExpired | Req::SignOut => {
                        tracing::debug!("Token expired or user signed out");
                        controller.auth.sign_out()?;
                        controller.tunnel_ready = false;
                        if let Some(mut session) = controller.session.take() {
                            tracing::debug!("disconnecting connlib");
                            // This is redundant if the token is expired, in that case
                            // connlib already disconnected itself.
                            session.connlib.disconnect(None);
                        }
                        else {
                            tracing::error!("tried to sign out but there's no session");
                        }
                        controller.refresh_system_tray_menu()?;
                    }
                    Req::ExportLogs{path, stem} => logging::export_logs_to(path, stem).await?,
                    Req::GetAdvancedSettings(tx) => {
                        tx.send(controller.advanced_settings.clone()).ok();
                    }
                    Req::Quit => break,
                    Req::SchemeRequest(url) => if let Err(e) = controller.handle_deep_link(&url).await {
                        tracing::error!("couldn't handle deep link: {e:#?}");
                    }
                    Req::SignIn => {
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
                    Req::StartStopLogCounting(enable) => {
                        if enable {
                            if controller.log_counting_task.is_none() {
                                let app = app.clone();
                                controller.log_counting_task = Some(tokio::spawn(logging::count_logs(app)));
                                tracing::debug!("started log counting");
                            }
                        } else if let Some(t) = controller.log_counting_task {
                            t.abort();
                            controller.log_counting_task = None;
                            tracing::debug!("cancelled log counting");
                        }
                    }
                    Req::TunnelReady => {
                        controller.tunnel_ready = true;
                        controller.refresh_system_tray_menu()?;

                        // May say "Windows Powershell" in dev mode
                        // See https://github.com/tauri-apps/tauri/issues/3700
                        Notification::new(&controller.app.config().tauri.bundle.identifier)
                            .title("Firezone connected")
                            .body("You are now signed in and able to access resources.")
                            .show()?;
                    },
                }
            }
        }
    }

    // Last chance to do any drops / cleanup before the process crashes.

    Ok(())
}
