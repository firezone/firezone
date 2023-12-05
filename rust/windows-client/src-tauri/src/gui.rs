//! The Tauri GUI for Windows

// TODO: `git grep` for unwraps before 1.0, especially this gui module

use anyhow::{anyhow, bail, Result};
use connlib_client_shared::file_logger;
use firezone_cli_utils::setup_global_subscriber;
use secrecy::SecretString;
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, result::Result as StdResult, time::Duration};
use tauri::{
    CustomMenuItem, Manager, SystemTray, SystemTrayEvent, SystemTrayMenu, SystemTrayMenuItem,
    SystemTraySubmenu,
};
use tokio::sync::{mpsc, oneshot};
use url::Url;
use ControllerRequest as Req;

pub fn run(app_link: Option<String>) -> Result<()> {
    // Make sure we're single-instance
    tauri_plugin_deep_link::prepare("dev.firezone");

    let rt = tokio::runtime::Runtime::new()?;
    let _guard = rt.enter();

    let (ctlr_tx, ctlr_rx) = mpsc::channel(5);

    let tray = SystemTray::new().with_menu(signed_out_menu());

    tauri::Builder::default()
        .manage(ctlr_tx)
        .on_window_event(|event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event.event() {
                // Keep the frontend running but just hide this webview
                // Per https://tauri.app/v1/guides/features/system-tray/#preventing-the-app-from-closing

                event.window().hide().unwrap();
                api.prevent_close();
            }
        })
        .invoke_handler(tauri::generate_handler![
            apply_advanced_settings,
            clear_logs,
            export_logs,
            get_advanced_settings,
        ])
        .system_tray(tray)
        .on_system_tray_event(|app, event| {
            if let SystemTrayEvent::MenuItemClick { id, .. } = event {
                match id.as_str() {
                    "/sign_in" => {
                        app.try_state::<mpsc::Sender<ControllerRequest>>()
                            .unwrap()
                            .blocking_send(ControllerRequest::SignIn)
                            .unwrap();
                    }
                    "/sign_out" => app.tray_handle().set_menu(signed_out_menu()).unwrap(),
                    "/about" => {
                        let win = app.get_window("about").unwrap();

                        if win.is_visible().unwrap() {
                            win.hide().unwrap();
                        } else {
                            win.show().unwrap();
                        }
                    }
                    "/settings" => {
                        let win = app.get_window("settings").unwrap();

                        if win.is_visible().unwrap() {
                            // If we close the window here, we can't re-open it, we'd have to fully re-create it. Not needed for MVP - We agreed 100 MB is fine for the GUI client.
                            win.hide().unwrap();
                        } else {
                            win.show().unwrap();
                        }
                    }
                    "/quit" => app.exit(0),
                    id => {
                        if let Some(addr) = id.strip_prefix("/resource/") {
                            tracing::warn!("TODO copy {addr} to clipboard");
                        }
                    }
                }
            }
        })
        .setup(|app| {
            // Change to data dir so the file logger will write there and not in System32 if we're launching from an app link
            let cwd = app
                .path_resolver()
                .app_local_data_dir()
                .ok_or_else(|| anyhow::anyhow!("can't get app_local_data_dir"))?
                .join("data");
            std::fs::create_dir_all(&cwd)?;
            std::env::set_current_dir(&cwd)?;

            // Set up logger with connlib_client_shared
            let (layer, _handle) = file_logger::layer(std::path::Path::new("logs"));
            setup_global_subscriber(layer);

            let _ctlr_task = tokio::spawn(run_controller(app.handle(), ctlr_rx));

            if let Some(_app_link) = app_link {
                // TODO: Handle app links that we catch at startup here
            }

            // From https://github.com/FabianLars/tauri-plugin-deep-link/blob/main/example/main.rs
            let handle = app.handle();
            tauri_plugin_deep_link::register("firezone", move |r| {
                let r = SecretString::new(r);
                let ctlr_tx = handle
                    .try_state::<mpsc::Sender<ControllerRequest>>()
                    .unwrap();
                ctlr_tx
                    .blocking_send(ControllerRequest::SchemeRequest(r))
                    .unwrap();
            })?;
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
    ctlr_tx: mpsc::Sender<ControllerRequest>,
    handle: Option<file_logger::Handle>,
}

impl connlib_client_shared::Callbacks for CallbackHandler {
    // TODO: add thiserror type
    type Error = std::convert::Infallible;

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
        tracing::debug!("on_update_resources");
        self.ctlr_tx
            .blocking_send(ControllerRequest::UpdateResources(resources))
            .unwrap();
        Ok(())
    }

    fn roll_log_file(&self) -> Option<PathBuf> {
        self.handle
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
    advanced_settings: AdvancedSettings,
    ctlr_tx: mpsc::Sender<ControllerRequest>,
    session: Option<connlib_client_shared::Session<CallbackHandler>>,
    token: Option<SecretString>,
}

impl Controller {
    async fn new(app: tauri::AppHandle) -> Result<Self> {
        let ctlr_tx = app
            .try_state::<mpsc::Sender<ControllerRequest>>()
            .ok_or_else(|| anyhow::anyhow!("can't get managed ctlr_tx"))?
            .inner()
            .clone();
        let mut advanced_settings = AdvancedSettings::default();
        if let Ok(s) = tokio::fs::read_to_string(advanced_settings_path(&app).await?).await {
            if let Ok(settings) = serde_json::from_str(&s) {
                advanced_settings = settings;
            } else {
                tracing::warn!("advanced_settings file not parsable");
            }
        } else {
            tracing::warn!("advanced_settings file doesn't exist");
        }

        tracing::trace!("re-loading token");
        let token: Option<SecretString> = tokio::task::spawn_blocking(|| {
            let entry = keyring_entry()?;
            match entry.get_password() {
                Ok(token) => {
                    tracing::debug!("re-loaded token from Windows credential manager");
                    Ok(Some(SecretString::new(token)))
                }
                Err(keyring::Error::NoEntry) => {
                    tracing::debug!("no token in Windows credential manager");
                    Ok(None)
                }
                Err(e) => Err(anyhow::Error::from(e)),
            }
        })
        .await??;

        let session = if let Some(token) = token.as_ref() {
            Some(Self::start_session(
                &advanced_settings,
                ctlr_tx.clone(),
                token,
            )?)
        } else {
            None
        };

        Ok(Self {
            advanced_settings,
            ctlr_tx,
            session,
            token,
        })
    }

    fn start_session(
        advanced_settings: &AdvancedSettings,
        ctlr_tx: mpsc::Sender<ControllerRequest>,
        token: &SecretString,
    ) -> Result<connlib_client_shared::Session<CallbackHandler>> {
        let (layer, handle) = file_logger::layer(std::path::Path::new("logs"));
        // TODO: How can I set up the tracing subscriber if the Session isn't ready yet? Check what other clients do.
        if false {
            // This helps the type inference
            setup_global_subscriber(layer);
        }

        tracing::info!("Session::connect");
        Ok(connlib_client_shared::Session::connect(
            advanced_settings.api_url.clone(),
            token.clone(),
            crate::device_id::get(),
            CallbackHandler {
                ctlr_tx,
                handle: Some(handle),
            },
        )?)
    }
}

async fn run_controller(
    app: tauri::AppHandle,
    mut rx: mpsc::Receiver<ControllerRequest>,
) -> Result<()> {
    let mut controller = Controller::new(app.clone()).await?;

    tracing::debug!("GUI controller main loop start");

    while let Some(req) = rx.recv().await {
        match req {
            Req::ExportLogs(file_path) => export_logs_to(file_path).await?,
            Req::GetAdvancedSettings(tx) => {
                tx.send(controller.advanced_settings.clone()).ok();
            }
            Req::SchemeRequest(req) => {
                use secrecy::ExposeSecret;

                if let Ok(auth) = parse_auth_callback(&req) {
                    tracing::debug!("setting new token");
                    let entry = keyring_entry()?;
                    entry.set_password(auth.token.expose_secret())?;
                    controller.session = Some(Controller::start_session(
                        &controller.advanced_settings,
                        controller.ctlr_tx.clone(),
                        &auth.token,
                    )?);
                    controller.token = Some(auth.token);
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
                tracing::debug!("got {} resources", resources.len());
            }
        }
    }
    tracing::debug!("GUI controller task exiting cleanly");
    Ok(())
}

pub(crate) struct AuthCallback {
    token: SecretString,
    _identifier: SecretString,
}

fn parse_auth_callback(input: &SecretString) -> Result<AuthCallback> {
    use secrecy::ExposeSecret;

    let url = url::Url::parse(input.expose_secret())?;

    let mut token = None;
    let mut identifier = None;

    for (key, value) in url.query_pairs() {
        match key.as_ref() {
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
        token: token.ok_or_else(|| anyhow!("expected client_auth_token"))?,
        _identifier: identifier.ok_or_else(|| anyhow!("expected identity_provider_identifier"))?,
    })
}

#[derive(Clone, Deserialize, Serialize)]
pub(crate) struct AdvancedSettings {
    auth_base_url: Url,
    api_url: Url,
    log_filter: String,
}

impl Default for AdvancedSettings {
    fn default() -> Self {
        Self {
            auth_base_url: Url::parse("https://app.firezone.dev").unwrap(),
            api_url: Url::parse("wss://api.firezone.dev").unwrap(),
            log_filter: "info".to_string(),
        }
    }
}

/// Gets the path for storing advanced settings, creating parent dirs if needed.
async fn advanced_settings_path(app: &tauri::AppHandle) -> Result<PathBuf> {
    let dir = app
        .path_resolver()
        .app_local_data_dir()
        .ok_or_else(|| anyhow::anyhow!("can't get app_local_data_dir"))?
        .join("config");
    tokio::fs::create_dir_all(&dir).await?;
    Ok(dir.join("advanced_settings.json"))
}

#[tauri::command]
async fn apply_advanced_settings(
    app: tauri::AppHandle,
    settings: AdvancedSettings,
) -> StdResult<(), String> {
    apply_advanced_settings_inner(app, settings)
        .await
        .map_err(|e| format!("{e}"))
}

#[tauri::command]
async fn clear_logs() -> StdResult<(), String> {
    clear_logs_inner().await.map_err(|e| format!("{e}"))
}

#[tauri::command]
async fn export_logs(
    ctlr_tx: tauri::State<'_, mpsc::Sender<ControllerRequest>>,
) -> StdResult<(), String> {
    export_logs_inner(ctlr_tx.inner().clone())
        .await
        .map_err(|e| format!("{e}"))
}

#[tauri::command]
async fn get_advanced_settings(
    ctlr_tx: tauri::State<'_, mpsc::Sender<ControllerRequest>>,
) -> StdResult<AdvancedSettings, String> {
    let (tx, rx) = oneshot::channel();
    ctlr_tx
        .send(ControllerRequest::GetAdvancedSettings(tx))
        .await
        .unwrap();
    Ok(rx.await.unwrap())
}

async fn apply_advanced_settings_inner(
    app: tauri::AppHandle,
    settings: AdvancedSettings,
) -> Result<()> {
    tokio::fs::write(
        advanced_settings_path(&app).await?,
        serde_json::to_string(&settings)?,
    )
    .await?;

    // TODO: This sleep is just for testing, remove it before it ships
    // TODO: Make sure the GUI handles errors if this function fails
    tokio::time::sleep(Duration::from_secs(1)).await;
    Ok(())
}

async fn clear_logs_inner() -> Result<()> {
    todo!()
}

async fn export_logs_inner(ctlr_tx: mpsc::Sender<ControllerRequest>) -> Result<()> {
    tauri::api::dialog::FileDialogBuilder::new()
        .add_filter("Zip", &["zip"])
        .save_file(move |file_path| match file_path {
            None => {}
            Some(x) => ctlr_tx
                .blocking_send(ControllerRequest::ExportLogs(x))
                .unwrap(),
        });
    Ok(())
}

async fn export_logs_to(file_path: PathBuf) -> Result<()> {
    tracing::trace!("Exporting logs to {file_path:?}");

    let mut entries = tokio::fs::read_dir("logs").await?;
    while let Some(entry) = entries.next_entry().await? {
        let path = entry.path();
        tracing::trace!("Export {path:?}");
    }
    tokio::time::sleep(Duration::from_secs(1)).await;
    // TODO: Somehow signal back to the GUI to unlock the log buttons when the export completes, or errors out
    Ok(())
}

fn _signed_in_menu(user_email: &str, resources: &[(&str, &str)]) -> SystemTrayMenu {
    let mut menu = SystemTrayMenu::new()
        .add_item(
            CustomMenuItem::new("".to_string(), format!("Signed in as {user_email}")).disabled(),
        )
        .add_item(CustomMenuItem::new("/sign_out".to_string(), "Sign out"))
        .add_native_item(SystemTrayMenuItem::Separator)
        .add_item(CustomMenuItem::new("".to_string(), "Resources").disabled());

    for (name, addr) in resources {
        let submenu = SystemTrayMenu::new().add_item(CustomMenuItem::new(
            format!("/resource/{addr}"),
            addr.to_string(),
        ));
        menu = menu.add_submenu(SystemTraySubmenu::new(name.to_string(), submenu));
    }

    menu = menu
        .add_native_item(SystemTrayMenuItem::Separator)
        .add_item(CustomMenuItem::new("/about".to_string(), "About"))
        .add_item(CustomMenuItem::new("/settings".to_string(), "Settings"))
        .add_item(CustomMenuItem::new("/quit".to_string(), "Quit Firezone").accelerator("Ctrl+Q"));

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
    use anyhow::Result;
    use secrecy::{ExposeSecret, SecretString};
    use std::str::FromStr;

    #[test]
    fn parse_auth_callback() -> Result<()> {
        let input = "firezone://handle_client_auth_callback/?actor_name=Reactor+Scram&client_auth_token=a_very_secret_string&identity_provider_identifier=12345";

        let actual = super::parse_auth_callback(&SecretString::from_str(input)?)?;

        assert_eq!(actual.token.expose_secret(), "a_very_secret_string");

        Ok(())
    }
}
