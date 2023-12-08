//! The Tauri GUI for Windows
//! This is not checked or compiled on other platforms.

// TODO: `git grep` for unwraps before 1.0, especially this gui module

use crate::settings::{self, AdvancedSettings};
use anyhow::{anyhow, bail, Result};
use connlib_client_shared::file_logger;
use firezone_cli_utils::setup_global_subscriber;
use secrecy::SecretString;
use std::{path::PathBuf, str::FromStr};
use tauri::{
    CustomMenuItem, Manager, SystemTray, SystemTrayEvent, SystemTrayMenu, SystemTrayMenuItem,
    SystemTraySubmenu,
};
use tokio::sync::{mpsc, oneshot};
use ControllerRequest as Req;

pub(crate) type CtlrTx = mpsc::Sender<ControllerRequest>;

pub(crate) fn app_local_data_dir(app: &tauri::AppHandle) -> Result<crate::AppLocalDataDir> {
    let path = app
        .path_resolver()
        .app_local_data_dir()
        .ok_or_else(|| anyhow!("getting app_local_data_dir"))?;
    Ok(crate::AppLocalDataDir(path))
}

/// All managed state that we might need to access from odd places like Tauri commands.
pub(crate) struct Managed {
    pub ctlr_tx: CtlrTx,
    pub inject_faults: bool,
}

/// Runs the Tauri GUI and returns on exit or unrecoverable error
pub(crate) fn run(params: crate::GuiParams) -> Result<()> {
    let crate::GuiParams {
        deep_link,
        inject_faults,
    } = params;

    // Make sure we're single-instance
    tauri_plugin_deep_link::prepare("dev.firezone");

    let rt = tokio::runtime::Runtime::new()?;
    let _guard = rt.enter();

    let (ctlr_tx, ctlr_rx) = mpsc::channel(5);
    let managed = Managed {
        ctlr_tx,
        inject_faults,
    };

    let tray = SystemTray::new().with_menu(signed_out_menu());

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
        .setup(|app| {
            // Change to data dir so the file logger will write there and not in System32 if we're launching from an app link
            let cwd = app_local_data_dir(&app.handle())?.0.join("data");
            std::fs::create_dir_all(&cwd)?;
            std::env::set_current_dir(&cwd)?;

            // Set up logger with connlib_client_shared
            let (layer, _handle) = file_logger::layer(std::path::Path::new("logs"));
            setup_global_subscriber(layer);

            let _ctlr_task = tokio::spawn(run_controller(app.handle(), ctlr_rx));

            if let Some(_deep_link) = deep_link {
                // TODO: Handle app links that we catch at startup here
            }

            // From https://github.com/FabianLars/tauri-plugin-deep-link/blob/main/example/main.rs
            let handle = app.handle();
            if let Err(e) = tauri_plugin_deep_link::register(crate::DEEP_LINK_SCHEME, move |url| {
                match handle_deep_link(&handle, url) {
                    Ok(()) => {}
                    Err(e) => tracing::error!("{e}"),
                }
            }) {
                tracing::error!("couldn't register deep link scheme: {e}");
            }
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

fn handle_deep_link(app: &tauri::AppHandle, url: String) -> Result<()> {
    Ok(app
        .try_state::<Managed>()
        .ok_or_else(|| anyhow!("can't get Managed object from Tauri"))?
        .ctlr_tx
        .blocking_send(ControllerRequest::SchemeRequest(SecretString::new(url)))?)
}

#[derive(Debug, PartialEq)]
enum TrayMenuEvent {
    About,
    Resource { id: String },
    Settings,
    SignIn,
    SignOut,
    Quit,
}

impl FromStr for TrayMenuEvent {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self> {
        Ok(match s {
            "/about" => Self::About,
            "/settings" => Self::Settings,
            "/sign_in" => Self::SignIn,
            "/sign_out" => Self::SignOut,
            "/quit" => Self::Quit,
            s => {
                if let Some(id) = s.strip_prefix("/resource/") {
                    Self::Resource { id: id.to_string() }
                } else {
                    anyhow::bail!("unknown system tray menu event");
                }
            }
        })
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
            .ok_or_else(|| anyhow!("getting ctlr_tx state"))?
            .ctlr_tx
            .blocking_send(ControllerRequest::SignIn)?,
        TrayMenuEvent::SignOut => app.tray_handle().set_menu(signed_out_menu())?,
        TrayMenuEvent::Quit => app.exit(0),
    }
    Ok(())
}

pub(crate) enum ControllerRequest {
    ExportLogs(PathBuf),
    GetAdvancedSettings(oneshot::Sender<AdvancedSettings>),
    // Secret because it will have the token in it
    SchemeRequest(SecretString),
    SignIn,
    UpdateResources(Vec<connlib_client_shared::ResourceDescription>),
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
    ctlr_tx: CtlrTx,
    logger: Option<file_logger::Handle>,
}

#[derive(thiserror::Error, Debug)]
enum CallbackError {
    #[error(transparent)]
    ControllerRequest(#[from] tokio::sync::mpsc::error::TrySendError<ControllerRequest>),
}

impl connlib_client_shared::Callbacks for CallbackHandler {
    type Error = CallbackError;

    fn on_disconnect(
        &self,
        error: Option<&connlib_client_shared::Error>,
    ) -> Result<(), Self::Error> {
        tracing::error!("on_disconnect {error:?}");
        Ok(())
    }

    fn on_error(&self, error: &connlib_client_shared::Error) -> Result<(), Self::Error> {
        tracing::error!("on_error not implemented. Error: {error:?}");
        Ok(())
    }

    fn on_update_resources(
        &self,
        resources: Vec<connlib_client_shared::ResourceDescription>,
    ) -> Result<(), Self::Error> {
        tracing::trace!("on_update_resources");
        // TODO: Better error handling?
        self.ctlr_tx
            .try_send(ControllerRequest::UpdateResources(resources))?;
        Ok(())
    }

    fn roll_log_file(&self) -> Option<PathBuf> {
        self.logger
            .as_ref()?
            .roll_to_new_file()
            .unwrap_or_else(|e| {
                tracing::debug!("Failed to roll over to new file: {e}");
                let _ = self.on_error(&connlib_client_shared::Error::LogFileRollError(e));

                None
            })
    }
}

struct Controller {
    /// Debugging-only settings like API URL, auth URL, log filter
    advanced_settings: AdvancedSettings,
    /// mpsc sender to send things to the controller task
    ctlr_tx: CtlrTx,
    /// connlib / tunnel session
    connlib_session: Option<connlib_client_shared::Session<CallbackHandler>>,
    /// Hexadecimal SHA256 of the on-disk UUIDv4
    /// Sent verbatim to Session::connect
    hashed_device_id: String,
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
    async fn new(app: tauri::AppHandle) -> Result<Self> {
        let ctlr_tx = app
            .try_state::<Managed>()
            .ok_or_else(|| anyhow::anyhow!("can't get Managed object from Tauri"))?
            .ctlr_tx
            .clone();
        let advanced_settings = settings::load_advanced_settings(&app)
            .await
            .unwrap_or_default();

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

        let hashed_device_id =
            crate::device_id::hashed_device_id(&app_local_data_dir(&app)?).await?;

        // Connect immediately if we reloaded the token
        let connlib_session = if let Some(session) = session.as_ref() {
            Some(Self::start_session(
                &advanced_settings,
                ctlr_tx.clone(),
                hashed_device_id.clone(),
                &session.token,
            )?)
        } else {
            None
        };

        Ok(Self {
            advanced_settings,
            ctlr_tx,
            connlib_session,
            hashed_device_id,
            session,
        })
    }

    fn start_session(
        advanced_settings: &settings::AdvancedSettings,
        ctlr_tx: CtlrTx,
        hashed_device_id: String,
        token: &SecretString,
    ) -> Result<connlib_client_shared::Session<CallbackHandler>> {
        let (layer, logger) = file_logger::layer(std::path::Path::new("logs"));
        // TODO: How can I set up the tracing subscriber if the Session isn't ready yet? Check what other clients do.
        if false {
            // This helps the type inference
            setup_global_subscriber(layer);
        }

        tracing::info!("Session::connect");
        Ok(connlib_client_shared::Session::connect(
            advanced_settings.api_url.clone(),
            token.clone(),
            hashed_device_id,
            CallbackHandler {
                ctlr_tx,
                logger: Some(logger),
            },
        )?)
    }
}

async fn run_controller(
    app: tauri::AppHandle,
    mut rx: mpsc::Receiver<ControllerRequest>,
) -> Result<()> {
    let mut controller = match Controller::new(app.clone()).await {
        Err(e) => {
            // TODO: There must be a shorter way to write these?
            tracing::error!("couldn't create controller: {e}");
            return Err(e);
        }
        Ok(x) => x,
    };

    tracing::debug!("GUI controller main loop start");

    while let Some(req) = rx.recv().await {
        match req {
            Req::ExportLogs(file_path) => settings::export_logs_to(file_path).await?,
            Req::GetAdvancedSettings(tx) => {
                tx.send(controller.advanced_settings.clone()).ok();
            }
            Req::SchemeRequest(req) => {
                use secrecy::ExposeSecret;

                if let Ok(auth) = parse_auth_callback(&req) {
                    tracing::debug!("setting new token");
                    let entry = keyring_entry()?;
                    entry.set_password(auth.token.expose_secret())?;
                    controller.connlib_session = Some(Controller::start_session(
                        &controller.advanced_settings,
                        controller.ctlr_tx.clone(),
                        controller.hashed_device_id.clone(),
                        &auth.token,
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
            Req::UpdateResources(resources) => {
                tracing::debug!("controller got UpdateResources");
                let resources: Vec<_> = resources.into_iter().map(ResourceDisplay::from).collect();

                // TODO: Save the user name between runs of the app
                let actor_name = controller
                    .session
                    .as_ref()
                    .map(|x| x.actor_name.as_str())
                    .unwrap_or("TODO");
                app.tray_handle()
                    .set_menu(signed_in_menu(actor_name, &resources))?;
            }
        }
    }
    tracing::debug!("GUI controller task exiting cleanly");
    Ok(())
}

pub(crate) struct AuthCallback {
    actor_name: String,
    token: SecretString,
    _identifier: SecretString,
}

fn parse_auth_callback(input: &SecretString) -> Result<AuthCallback> {
    use secrecy::ExposeSecret;

    let url = url::Url::parse(input.expose_secret())?;

    let mut actor_name = None;
    let mut token = None;
    let mut identifier = None;

    for (key, value) in url.query_pairs() {
        match key.as_ref() {
            "actor_name" => {
                if actor_name.is_some() {
                    bail!("actor_name must appear exactly once");
                }
                actor_name = Some(value.to_string());
            }
            "client_auth_token" => {
                if token.is_some() {
                    bail!("client_auth_token must appear exactly once");
                }
                token = Some(SecretString::new(value.to_string()));
            }
            "identity_provider_identifier" => {
                if identifier.is_some() {
                    bail!("identity_provider_identifier must appear exactly once");
                }
                identifier = Some(SecretString::new(value.to_string()));
            }
            _ => {}
        }
    }

    Ok(AuthCallback {
        actor_name: actor_name.ok_or_else(|| anyhow!("expected actor_name"))?,
        token: token.ok_or_else(|| anyhow!("expected client_auth_token"))?,
        _identifier: identifier.ok_or_else(|| anyhow!("expected identity_provider_identifier"))?,
    })
}

/// The information needed for the GUI to display a resource inside the Firezone VPN
struct ResourceDisplay {
    id: connlib_shared::messages::ResourceId,
    /// User-friendly name, e.g. "GitLab"
    name: String,
    /// What will be copied to the clipboard to paste into a web browser
    pastable: String,
}

impl From<connlib_client_shared::ResourceDescription> for ResourceDisplay {
    fn from(x: connlib_client_shared::ResourceDescription) -> Self {
        match x {
            connlib_client_shared::ResourceDescription::Dns(x) => Self {
                id: x.id,
                name: x.name,
                pastable: x.address,
            },
            connlib_client_shared::ResourceDescription::Cidr(x) => Self {
                id: x.id,
                name: x.name,
                // TODO: CIDRs aren't URLs right?
                pastable: x.address.to_string(),
            },
        }
    }
}

fn signed_in_menu(user_name: &str, resources: &[ResourceDisplay]) -> SystemTrayMenu {
    let mut menu = SystemTrayMenu::new()
        .add_item(
            CustomMenuItem::new("".to_string(), format!("Signed in as {user_name}")).disabled(),
        )
        .add_item(CustomMenuItem::new("/sign_out".to_string(), "Sign out"))
        .add_native_item(SystemTrayMenuItem::Separator)
        .add_item(CustomMenuItem::new("".to_string(), "Resources").disabled());

    for ResourceDisplay { id, name, pastable } in resources {
        let submenu = SystemTrayMenu::new().add_item(CustomMenuItem::new(
            format!("/resource/{id}"),
            pastable.to_string(),
        ));
        menu = menu.add_submenu(SystemTraySubmenu::new(name, submenu));
    }

    menu = menu
        .add_native_item(SystemTrayMenuItem::Separator)
        .add_item(CustomMenuItem::new("/about".to_string(), "About"))
        .add_item(CustomMenuItem::new("/settings".to_string(), "Settings"))
        .add_item(
            CustomMenuItem::new("/quit".to_string(), "Disconnect and quit Firezone")
                .accelerator("Ctrl+Q"),
        );

    menu
}

fn signed_out_menu() -> SystemTrayMenu {
    SystemTrayMenu::new()
        .add_item(CustomMenuItem::new("/sign_in".to_string(), "Sign In"))
        .add_native_item(SystemTrayMenuItem::Separator)
        .add_item(CustomMenuItem::new("/about".to_string(), "About"))
        .add_item(CustomMenuItem::new("/settings".to_string(), "Settings"))
        .add_item(CustomMenuItem::new("/quit".to_string(), "Quit Firezone").accelerator("Ctrl+Q"))
}

#[cfg(test)]
mod tests {
    use super::TrayMenuEvent;
    use anyhow::Result;
    use secrecy::{ExposeSecret, SecretString};
    use std::str::FromStr;

    #[test]
    fn parse_auth_callback() -> Result<()> {
        let input = "firezone://handle_client_auth_callback/?actor_name=Reactor+Scram&client_auth_token=a_very_secret_string&identity_provider_identifier=12345";

        let actual = super::parse_auth_callback(&SecretString::from_str(input)?)?;

        assert_eq!(actual.actor_name, "Reactor Scram");
        assert_eq!(actual.token.expose_secret(), "a_very_secret_string");

        Ok(())
    }

    #[test]
    fn systray_parse() {
        assert_eq!(
            TrayMenuEvent::from_str("/about").unwrap(),
            TrayMenuEvent::About
        );
        assert_eq!(
            TrayMenuEvent::from_str("/resource/1234").unwrap(),
            TrayMenuEvent::Resource {
                id: "1234".to_string()
            }
        );
        assert_eq!(
            TrayMenuEvent::from_str("/resource/quit").unwrap(),
            TrayMenuEvent::Resource {
                id: "quit".to_string()
            }
        );
        assert_eq!(
            TrayMenuEvent::from_str("/sign_out").unwrap(),
            TrayMenuEvent::SignOut
        );
        assert_eq!(
            TrayMenuEvent::from_str("/quit").unwrap(),
            TrayMenuEvent::Quit
        );

        assert!(TrayMenuEvent::from_str("/unknown").is_err());
    }
}
