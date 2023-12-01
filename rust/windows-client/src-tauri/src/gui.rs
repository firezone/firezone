//! The Tauri GUI for Windows

use crate::prelude::*;
use connlib_client_shared::file_logger;
use tauri::{
    CustomMenuItem, Manager, SystemTray, SystemTrayEvent, SystemTrayMenu, SystemTrayMenuItem,
    SystemTraySubmenu,
};

// TODO: Decide whether Windows needs to handle env vars and CLI args for IDs / tokens
pub fn main(_: Option<CommonArgs>, app_link: Option<String>) -> Result<()> {
    // Set up logger with connlib_client_shared
    let (layer, _handle) = file_logger::layer(std::path::Path::new("."));
    setup_global_subscriber(layer);

    // Make sure we're single-instance
    tauri_plugin_deep_link::prepare("dev.firezone");

    let tray = SystemTray::new().with_menu(signed_out_menu());

    tauri::Builder::default()
        .on_window_event(|event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event.event() {
                // Keep the frontend running but just hide this webview
                // Per https://tauri.app/v1/guides/features/system-tray/#preventing-the-app-from-closing

                event.window().hide().unwrap();
                api.prevent_close();
            }
        })
        .invoke_handler(tauri::generate_handler![greet])
        .system_tray(tray)
        .on_system_tray_event(|app, event| {
            if let SystemTrayEvent::MenuItemClick { id, .. } = event {
                match id.as_str() {
                    "/sign_in" => {
                        // TODO: This whole method is a sync callback that can't do error handling. Send an event over a channel to somewhere async with error handling.

                        // TODO: Use auth base URL and account ID
                        // And client_platform=windows
                        open::that("https://app.firez.one/firezone?client_csrf_token=bogus&client_platform=apple").unwrap();

                        // TODO: Move this to the sign_in_handle_callback handler
                        app.tray_handle()
                            .set_menu(signed_in_menu(
                                "user@example.com",
                                &[("CloudFlare", "1.1.1.1"), ("Google", "8.8.8.8")],
                            ))
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

// Learn more about Tauri commands at https://tauri.app/v1/guides/features/command
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

fn signed_in_menu(user_email: &str, resources: &[(&str, &str)]) -> SystemTrayMenu {
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
