//! The Tauri GUI for Windows
//! This is not checked or compiled on other platforms.

// TODO: `git grep` for unwraps before 1.0, especially this gui module

use crate::client::{self, deep_link, AppLocalDataDir};
use anyhow::{anyhow, Context, Result};
use arc_swap::ArcSwap;
use client::settings::{self, AdvancedSettings};
use connlib_client_shared::{file_logger, ResourceDescription};
use secrecy::{ExposeSecret, SecretString};
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    path::PathBuf,
    str::FromStr,
    sync::Arc,
};
use system_tray_menu::{Event as TrayMenuEvent, Resource as ResourceDisplay};
use tauri::{Manager, SystemTray, SystemTrayEvent};
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
pub(crate) struct Managed {
    pub ctlr_tx: CtlrTx,
    pub inject_faults: bool,
}

// TODO: We're supposed to get this from Tauri, but I'd need to move some things around first
const TAURI_ID: &str = "dev.firezone.client";

/// Runs the Tauri GUI and returns on exit or unrecoverable error
pub(crate) fn run(params: client::GuiParams) -> Result<()> {
    let client::GuiParams {
        flag_elevated,
        inject_faults,
    } = params;

    // Needed for the deep link server
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
        ctlr_tx,
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
            settings::apply_advanced_settings,
            settings::clear_logs,
            settings::export_logs,
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
            // I checked this on my dev system to make sure Powershell is doing what I expect and passing the argument back to us after relaunch
            tracing::debug!("flag_elevated: {flag_elevated}");

            let app_handle = app.handle();
            let _ctlr_task = tokio::spawn(async move {
                if let Err(e) = run_controller(
                    app_handle,
                    ctlr_rx,
                    logging_handles,
                    advanced_settings,
                    notify_controller,
                )
                .await
                {
                    tracing::error!("run_controller returned an error: {e}");
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
        TrayMenuEvent::Resource { id } => tracing::warn!("TODO copy {id} to clipboard"),
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
        TrayMenuEvent::SignIn => app
            .try_state::<Managed>()
            .ok_or_else(|| anyhow!("couldn't get ctlr_tx state"))?
            .ctlr_tx
            .blocking_send(ControllerRequest::SignIn)?,
        TrayMenuEvent::SignOut => app
            .try_state::<Managed>()
            .ok_or_else(|| anyhow!("couldn't get ctlr_tx state"))?
            .ctlr_tx
            .blocking_send(ControllerRequest::SignOut)?,
        TrayMenuEvent::Quit => app.exit(0),
    }
    Ok(())
}

pub(crate) enum ControllerRequest {
    ExportLogs(PathBuf),
    GetAdvancedSettings(oneshot::Sender<AdvancedSettings>),
    SchemeRequest(url::Url),
    SignIn,
    SignOut,
}

// TODO: Should these be keyed to the Google ID or email or something?
// The callback returns a human-readable name but those aren't good keys.
fn keyring_entry() -> Result<keyring::Entry> {
    Ok(keyring::Entry::new_with_target(
        "token",
        "firezone_windows_client",
        "",
    )?)
}

#[derive(Clone)]
struct CallbackHandler {
    logger: file_logger::Handle,
    notify_controller: Arc<Notify>,
    resources: Arc<ArcSwap<Vec<ResourceDescription>>>,
}

#[derive(thiserror::Error, Debug)]
enum CallbackError {
    #[error("couldn't send message to Controller task: {0}")]
    MessageSend(#[from] std::sync::mpsc::SendError<ControllerRequest>),
}

// Callbacks must all be non-blocking
impl connlib_client_shared::Callbacks for CallbackHandler {
    type Error = CallbackError;

    fn on_disconnect(
        &self,
        error: Option<&connlib_client_shared::Error>,
    ) -> Result<(), Self::Error> {
        tracing::warn!("on_disconnect {error:?}");
        Ok(())
    }

    fn on_error(&self, error: &connlib_client_shared::Error) -> Result<(), Self::Error> {
        tracing::error!("on_error not implemented. Error: {error:?}");
        Ok(())
    }

    fn on_set_interface_config(
        &self,
        tunnel_addr_ipv4: Ipv4Addr,
        _tunnel_addr_ipv6: Ipv6Addr,
        _dns_addr: Ipv4Addr,
    ) -> Result<Option<i32>, Self::Error> {
        tracing::info!("Tunnel IPv4 = {tunnel_addr_ipv4}");
        Ok(None)
    }

    fn on_tunnel_ready(&self) -> Result<(), Self::Error> {
        tracing::info!("on_tunnel_ready");
        Ok(())
    }

    fn on_update_resources(&self, resources: Vec<ResourceDescription>) -> Result<(), Self::Error> {
        self.resources.store(resources.into());
        self.notify_controller.notify_one();
        Ok(())
    }

    fn roll_log_file(&self) -> Option<PathBuf> {
        self.logger.roll_to_new_file().unwrap_or_else(|e| {
            tracing::debug!("Failed to roll over to new file: {e}");
            let _ = self.on_error(&connlib_client_shared::Error::LogFileRollError(e));

            None
        })
    }
}

struct Controller {
    /// Debugging-only settings like API URL, auth URL, log filter
    advanced_settings: AdvancedSettings,
    /// connlib / tunnel session
    connlib_session: Option<connlib_client_shared::Session<CallbackHandler>>,
    /// The UUIDv4 device ID persisted to disk
    /// Sent verbatim to Session::connect
    device_id: String,
    logging_handles: client::logging::Handles,
    /// Tells us when to wake up and look for a new resource list. Tokio docs say that memory reads and writes are synchronized when notifying, so we don't need an extra mutex on the resources.
    notify_controller: Arc<Notify>,
    resources: Arc<ArcSwap<Vec<ResourceDescription>>>,
    /// Info about currently signed-in user, if there is one
    session: Option<Session>,
}

/// Information for a signed-in user session
struct Session {
    /// User name, e.g. "John Doe", from the sign-in deep link
    actor_name: String,
    token: SecretString,
}

impl Controller {
    async fn new(
        app: tauri::AppHandle,
        logging_handles: client::logging::Handles,
        advanced_settings: AdvancedSettings,
        notify_controller: Arc<Notify>,
    ) -> Result<Self> {
        tracing::trace!("re-loading token");
        let session: Option<Session> = tokio::task::spawn_blocking(|| {
            let entry = keyring_entry()?;
            match entry.get_password() {
                Ok(token) => {
                    let token = SecretString::new(token);
                    tracing::debug!("re-loaded token from Windows credential manager");
                    let session = Session {
                        actor_name: "TODO".to_string(),
                        token,
                    };
                    Ok(Some(session))
                }
                Err(keyring::Error::NoEntry) => {
                    tracing::debug!("no token in Windows credential manager");
                    Ok(None)
                }
                Err(e) => Err(anyhow::Error::from(e)),
            }
        })
        .await??;

        let device_id = client::device_id::device_id(&app_local_data_dir(&app)?).await?;

        let resources = Default::default();

        // Connect immediately if we reloaded the token
        let connlib_session = if let Some(session) = session.as_ref() {
            Some(Self::start_session(
                &advanced_settings,
                device_id.clone(),
                &session.token,
                logging_handles.logger.clone(),
                Arc::clone(&notify_controller),
                Arc::clone(&resources),
            )?)
        } else {
            None
        };

        Ok(Self {
            advanced_settings,
            connlib_session,
            device_id,
            logging_handles,
            notify_controller,
            resources,
            session,
        })
    }

    fn start_session(
        advanced_settings: &settings::AdvancedSettings,
        device_id: String,
        token: &SecretString,
        logger: file_logger::Handle,
        notify_controller: Arc<Notify>,
        resources: Arc<ArcSwap<Vec<ResourceDescription>>>,
    ) -> Result<connlib_client_shared::Session<CallbackHandler>> {
        tracing::info!("Session::connect");
        Ok(connlib_client_shared::Session::connect(
            advanced_settings.api_url.clone(),
            token.clone(),
            device_id,
            CallbackHandler {
                logger,
                notify_controller,
                resources,
            },
        )?)
    }
}

// TODO: After PR #2960 lands, move some of this into `impl Controller`
async fn run_controller(
    app: tauri::AppHandle,
    mut rx: mpsc::Receiver<ControllerRequest>,
    logging_handles: client::logging::Handles,
    advanced_settings: AdvancedSettings,
    notify_controller: Arc<Notify>,
) -> Result<()> {
    let mut controller = Controller::new(
        app.clone(),
        logging_handles,
        advanced_settings,
        notify_controller,
    )
    .await
    .context("couldn't create Controller")?;

    tracing::debug!("GUI controller main loop start");

    loop {
        tokio::select! {
            () = controller.notify_controller.notified() => {
                let resources = controller.resources.load().as_ref().clone();
                let resources: Vec<_> = resources.into_iter().map(ResourceDisplay::from).collect();
                tracing::debug!("controller sees {} resources", resources.len());
                // TODO: Save the user name between runs of the app
                let actor_name = controller
                    .session
                    .as_ref()
                    .map(|x| x.actor_name.as_str())
                    .unwrap_or("TODO");
                app.tray_handle()
                    .set_menu(system_tray_menu::signed_in(actor_name, &resources))?;
            }
            req = rx.recv() => {
                let Some(req) = req else {
                    break;
                };
                 match req {
                    Req::ExportLogs(file_path) => settings::export_logs_to(file_path).await?,
                    Req::GetAdvancedSettings(tx) => {
                        tx.send(controller.advanced_settings.clone()).ok();
                    }
                    Req::SchemeRequest(url) => {
                        if let Some(auth) = client::deep_link::parse_auth_callback(&url) {
                            tracing::debug!("setting new token");
                            let entry = keyring_entry()?;
                            entry.set_password(auth.token.expose_secret())?;
                            controller.connlib_session = Some(Controller::start_session(
                                &controller.advanced_settings,
                                controller.device_id.clone(),
                                &auth.token,
                                controller.logging_handles.logger.clone(),
                                Arc::clone(&controller.notify_controller),
                                Arc::clone(&controller.resources),
                            )?);
                            controller.session = Some(Session {
                                actor_name: auth.actor_name,
                                token: auth.token,
                            });
                        } else {
                            tracing::warn!("couldn't handle scheme request");
                        }
                    }
                    Req::SignIn => {
                        // TODO: Put the platform and local server callback in here
                        tauri::api::shell::open(
                            &app.shell_scope(),
                            &controller.advanced_settings.auth_base_url,
                            None,
                        )?;
                    }
                    Req::SignOut => {
                        keyring_entry()?.delete_password()?;
                        if let Some(mut session) = controller.connlib_session.take() {
                            // TODO: Needs testing
                            session.disconnect(None);
                        }
                        app.tray_handle().set_menu(system_tray_menu::signed_out())?;
                    }
                }
            }
        }
    }
    tracing::debug!("GUI controller task exiting cleanly");
    Ok(())
}
