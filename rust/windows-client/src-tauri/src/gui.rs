//! The Tauri GUI for Windows

use crate::prelude::*;
use connlib_client_shared::file_logger;
use serde::{Deserialize, Serialize};
use std::result::Result as StdResult;
use std::time::Duration;
use tauri::{
    CustomMenuItem, Manager, SystemTray, SystemTrayEvent, SystemTrayMenu, SystemTrayMenuItem,
    SystemTraySubmenu,
};
use tokio::sync::{mpsc, oneshot};

struct State {
    ctlr_tx: mpsc::Sender<ControllerRequest>,
}

// TODO: Decide whether Windows needs to handle env vars and CLI args for IDs / tokens
pub fn main(_: Option<CommonArgs>, app_link: Option<String>) -> Result<()> {
    // Set up logger with connlib_client_shared
    let (layer, _handle) = file_logger::layer(std::path::Path::new("."));
    setup_global_subscriber(layer);

    // Make sure we're single-instance
    tauri_plugin_deep_link::prepare("dev.firezone");

    let rt = tokio::runtime::Runtime::new()?;
    let _guard = rt.enter();

    let (ctlr_tx, ctlr_rx) = mpsc::channel(5);
    let _ctlr_task = tokio::spawn(controller(ctlr_rx));

    // TODO: #2711, commit to URI schemes or local webserver/c
    // let _webserver_task = tokio::spawn(local_webserver(ctlr_tx.clone()));

    let tray = SystemTray::new().with_menu(signed_out_menu());

    tauri::Builder::default()
        .manage(State { ctlr_tx })
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
            get_advanced_settings,
        ])
        .system_tray(tray)
        .on_system_tray_event(|app, event| {
            if let SystemTrayEvent::MenuItemClick { id, .. } = event {
                match id.as_str() {
                    "/sign_in" => {
                        app.try_state::<State>()
                            .unwrap()
                            .ctlr_tx
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
                        dbg!(win.url());

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
                            println!("TODO copy {addr} to clipboard");
                        }
                    }
                }
            }
        })
        .setup(|app| {
            if let Some(_app_link) = app_link {
                // TODO: Handle app links that we catch at startup here
            }

            app.listen_global("scheme-request-received", |event| {
                // TODO: Handle "firezone://handle_client_auth_callback/?client_csrf_token=bogus_csrf_token&actor_name=Bogus+Name&client_auth_token=bogus_auth_token"
                println!("got scheme request {:?}", event.payload());
            });

            // From https://github.com/FabianLars/tauri-plugin-deep-link/blob/main/example/main.rs
            let handle = app.handle();
            tauri_plugin_deep_link::register("firezone", move |request| {
                dbg!(&request);
                handle.trigger_global("scheme-request-received", Some(request));
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
    GetAdvancedSettings(oneshot::Sender<AdvancedSettings>),
    SignIn,
}

async fn controller(mut rx: mpsc::Receiver<ControllerRequest>) -> Result<()> {
    use ControllerRequest as Req;

    let mut advanced_settings = AdvancedSettings::default();
    // TODO: Load advanced settings here
    if let Ok(s) = tokio::fs::read_to_string(advanced_settings_path().await?).await {
        if let Ok(settings) = serde_json::from_str(&s) {
            advanced_settings = settings;
        } else {
            tracing::warn!("advanced_settings file not parsable");
        }
    } else {
        tracing::warn!("advanced_settings file doesn't exist");
    }

    while let Some(req) = rx.recv().await {
        match req {
            Req::GetAdvancedSettings(tx) => {
                tx.send(advanced_settings.clone()).ok();
            }
            Req::SignIn => {
                // TODO: Put the platform and local server callback in here
                open::that(&advanced_settings.auth_base_url)?;
            }
        }
    }
    tracing::debug!("GUI controller task exiting cleanly");
    Ok(())
}

#[derive(Clone, Deserialize, Serialize)]
pub(crate) struct AdvancedSettings {
    auth_base_url: String,
    api_url: String,
    log_filter: String,
}

impl Default for AdvancedSettings {
    fn default() -> Self {
        Self {
            auth_base_url: "https://app.firezone.dev".to_string(),
            api_url: "wss://api.firezone.dev".to_string(),
            log_filter: "info".to_string(),
        }
    }
}

/// Gets the path for storing advanced settings, creating parent dirs if needed.
async fn advanced_settings_path() -> Result<PathBuf> {
    let dirs = crate::cli::get_project_dirs()?;
    let dir = dirs.config_local_dir();
    tokio::fs::create_dir_all(dir).await?;
    Ok(dir.join("advanced_settings.json"))
}

#[tauri::command]
async fn get_advanced_settings(
    state: tauri::State<'_, State>,
) -> StdResult<AdvancedSettings, String> {
    let (tx, rx) = oneshot::channel();
    state
        .ctlr_tx
        .send(ControllerRequest::GetAdvancedSettings(tx))
        .await
        .unwrap();
    Ok(rx.await.unwrap())
}

#[tauri::command]
async fn apply_advanced_settings(settings: AdvancedSettings) -> StdResult<(), String> {
    apply_advanced_settings_inner(settings)
        .await
        .map_err(|e| format!("{e}"))
}

async fn apply_advanced_settings_inner(settings: AdvancedSettings) -> Result<()> {
    tokio::fs::write(
        advanced_settings_path().await?,
        serde_json::to_string(&settings)?,
    )
    .await?;

    // TODO: This sleep is just for testing, remove it before it ships
    // TODO: Make sure the GUI handles errors if this function fails
    tokio::time::sleep(Duration::from_secs(1)).await;
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
