//! The Tauri GUI for Windows
//! This is not checked or compiled on other platforms.

// TODO: `git grep` for unwraps before 1.0, especially this gui module

use crate::client::{self, deep_link, AppLocalDataDir};
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
use tauri::{Manager, SystemTray, SystemTrayEvent};
use tokio::{
    sync::{mpsc, oneshot, Notify},
    task::spawn_blocking,
};
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
            // I checked this on my dev system to make sure Powershell is doing what I expect and passing the argument back to us after relaunch
            tracing::debug!("flag_elevated: {flag_elevated}");

            let app_handle = app.handle();
            let _ctlr_task = tokio::spawn(async move {
                if let Err(e) = run_controller(
                    app_handle,
                    ctlr_tx,
                    ctlr_rx,
                    logging_handles,
                    advanced_settings,
                    notify_controller,
                )
                .await
                {
                    tracing::error!("run_controller returned an error: {e:#?}");
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
        TrayMenuEvent::Quit => app.exit(0),
    }
    Ok(())
}

pub(crate) enum ControllerRequest {
    CopyResource(String),
    Disconnected,
    DisconnectedTokenExpired,
    ExportLogs { path: PathBuf, stem: PathBuf },
    GetAdvancedSettings(oneshot::Sender<AdvancedSettings>),
    SchemeRequest(url::Url),
    SignIn,
    StartStopLogCounting(bool),
    SignOut,
}

// TODO: Should these be keyed to the Google ID or email or something?
// The callback returns a human-readable name but those aren't good keys.
fn keyring_entry() -> Result<keyring::Entry> {
    Ok(keyring::Entry::new_with_target(
        "dev.firezone.client/token",
        "",
        "",
    )?)
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

    fn on_error(&self, error: &connlib_client_shared::Error) -> Result<(), Self::Error> {
        tracing::error!("on_error not implemented. Error: {error:?}");
        Ok(())
    }

    fn on_tunnel_ready(&self) -> Result<(), Self::Error> {
        // TODO: implement
        tracing::info!("on_tunnel_ready");
        Ok(())
    }

    fn on_update_resources(&self, resources: Vec<ResourceDescription>) -> Result<(), Self::Error> {
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
            let _ = self.on_error(&connlib_client_shared::Error::LogFileRollError(e));

            None
        })
    }
}

struct Controller {
    /// Debugging-only settings like API URL, auth URL, log filter
    advanced_settings: AdvancedSettings,
    app: tauri::AppHandle,
    ctlr_tx: CtlrTx,
    /// Session for the currently signed-in user, if there is one
    session: Option<Session>,
    /// The UUIDv4 device ID persisted to disk
    /// Sent verbatim to Session::connect
    device_id: String,
    log_counting_task: Option<tokio::task::JoinHandle<Result<()>>>,
    logging_handles: client::logging::Handles,
    /// Tells us when to wake up and look for a new resource list. Tokio docs say that memory reads and writes are synchronized when notifying, so we don't need an extra mutex on the resources.
    notify_controller: Arc<Notify>,
}

/// Everything related to a signed-in user session
struct Session {
    auth_info: AuthInfo,
    callback_handler: CallbackHandler,
    connlib: connlib_client_shared::Session<CallbackHandler>,
}

/// Auth info that's persisted to disk if a session outlives an app instance
struct AuthInfo {
    /// User name, e.g. "John Doe", from the sign-in deep link
    actor_name: String,
    /// Secret token to authenticate with the portal
    token: SecretString,
}

impl Controller {
    async fn new(
        app: tauri::AppHandle,
        ctlr_tx: CtlrTx,
        logging_handles: client::logging::Handles,
        advanced_settings: AdvancedSettings,
        notify_controller: Arc<Notify>,
    ) -> Result<Self> {
        let device_id = client::device_id::device_id(&app_local_data_dir(&app)?).await?;

        let mut this = Self {
            advanced_settings,
            app,
            ctlr_tx,
            session: None,
            device_id,
            log_counting_task: None,
            logging_handles,
            notify_controller,
        };

        tracing::trace!("re-loading token");
        // spawn_blocking because accessing the keyring is I/O
        if let Some(auth_info) = spawn_blocking(|| {
            let entry = keyring_entry()?;
            match entry.get_password() {
                Ok(token) => {
                    let token = SecretString::new(token);
                    tracing::debug!("re-loaded token from Windows credential manager");
                    let auth_info = AuthInfo {
                        // TODO: Reload actor name from disk here
                        actor_name: "TODO".to_string(),
                        token,
                    };
                    Ok(Some(auth_info))
                }
                Err(keyring::Error::NoEntry) => {
                    tracing::debug!("no token in Windows credential manager");
                    Ok(None)
                }
                Err(e) => Err(anyhow::Error::from(e)),
            }
        })
        .await??
        {
            // Connect immediately if we reloaded the token
            if let Err(e) = this.start_session(auth_info) {
                tracing::error!("couldn't restart session on app start: {e:#?}");
            }
        }

        Ok(this)
    }

    // TODO: Figure out how re-starting sessions automatically will work
    fn start_session(&mut self, auth_info: AuthInfo) -> Result<()> {
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
            auth_info.token.clone(),
            self.device_id.clone(),
            None, // TODO: Send device name here (windows computer name)
            None,
            callback_handler.clone(),
            Duration::from_secs(5 * 60),
        )?;

        self.session = Some(Session {
            auth_info,
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
        let Some(auth) = client::deep_link::parse_auth_callback(url) else {
            // TODO: `bail` is redundant here, just do `.context("")?;` since it's `anyhow`
            bail!("couldn't parse scheme request");
        };

        let token = auth.token.clone();
        // spawn_blocking because keyring access is I/O
        if let Err(e) = spawn_blocking(move || {
            let entry = keyring_entry()?;
            entry.set_password(token.expose_secret())?;
            Ok::<_, anyhow::Error>(())
        })
        .await?
        {
            tracing::error!("couldn't save token to keyring: {e:#?}");
        }

        let auth_info = AuthInfo {
            actor_name: auth.actor_name,
            token: auth.token,
        };
        if let Err(e) = self.start_session(auth_info) {
            // TODO: Replace `bail` with `context` here too
            bail!("couldn't start session: {e:#?}");
        }
        Ok(())
    }

    fn reload_resource_list(&mut self) -> Result<()> {
        let Some(session) = &self.session else {
            tracing::warn!("got notified to update resources but there is no session");
            return Ok(());
        };
        let resources = session.callback_handler.resources.load();
        // TODO: Save the user name between runs of the app
        let actor_name = self
            .session
            .as_ref()
            .map(|x| x.auth_info.actor_name.as_str())
            .unwrap_or("TODO");
        self.app
            .tray_handle()
            .set_menu(system_tray_menu::signed_in(actor_name, &resources))?;
        Ok(())
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

    loop {
        tokio::select! {
            () = controller.notify_controller.notified() => if let Err(e) = controller.reload_resource_list() {
                tracing::error!("couldn't reload resource list: {e:#?}");
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
                        if let Some(mut session) = controller.session.take() {
                            tracing::debug!("disconnecting connlib");
                            // This is probably redundant since connlib shuts itself down if it's disconnected.
                            session.connlib.disconnect(None);
                        }
                    }
                    Req::DisconnectedTokenExpired | Req::SignOut => {
                        tracing::debug!("Token expired or user signed out");
                        // TODO: After we store the actor name on disk, clear the actor name here too.
                        keyring_entry()?.delete_password()?;
                        if let Some(mut session) = controller.session.take() {
                            tracing::debug!("disconnecting connlib");
                            session.connlib.disconnect(None);
                        }
                        else {
                            tracing::error!("tried to sign out but there's no session");
                        }
                        app.tray_handle().set_menu(system_tray_menu::signed_out())?;
                    }
                    Req::ExportLogs{path, stem} => logging::export_logs_to(path, stem).await?,
                    Req::GetAdvancedSettings(tx) => {
                        tx.send(controller.advanced_settings.clone()).ok();
                    }
                    Req::SchemeRequest(url) => if let Err(e) = controller.handle_deep_link(&url).await {
                        tracing::error!("couldn't handle deep link: {e:#?}");
                    }
                    Req::SignIn => {
                        // TODO: Put the platform and local server callback in here
                        tauri::api::shell::open(
                            &app.shell_scope(),
                            &controller.advanced_settings.auth_base_url,
                            None,
                        )?;
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
                }
            }
        }
    }
    tracing::debug!("GUI controller task exiting cleanly");
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_keyring() -> anyhow::Result<()> {
        // I used this test to find that `service` is not used - We have to namespace on our own.

        let name_1 = "dev.firezone.client/test_1/token";
        let name_2 = "dev.firezone.client/test_2/token";

        keyring::Entry::new_with_target(name_1, "", "")?.set_password("test_password_1")?;

        keyring::Entry::new_with_target(name_2, "", "")?.set_password("test_password_2")?;

        let actual = keyring::Entry::new_with_target(name_1, "", "")?.get_password()?;
        let expected = "test_password_1";

        assert_eq!(actual, expected);

        keyring::Entry::new_with_target(name_1, "", "")?.delete_password()?;
        keyring::Entry::new_with_target(name_2, "", "")?.delete_password()?;

        Ok(())
    }
}
