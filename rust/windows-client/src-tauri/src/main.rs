// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use thiserror::Error;

#[derive(Error, Debug)]
enum Error {}

fn main() {
    let mut args = std::env::args();
    // Ignore the exe name
    args.next().unwrap();

    match args.next().as_deref() {
        None | Some("tauri") => tauri::main(),
        Some("debug") => println!("debug"),
        Some("debug-connlib") => main_debug_connlib(),
        Some(cmd) => println!("Subcommand `{cmd}` not recognized"),
    }
}

fn main_debug_connlib() {
    use connlib_client_shared::Error as ConnlibError;
    use connlib_client_shared::{Callbacks, Session};
    use std::str::FromStr;

    #[derive(Clone, Default)]
    struct WindowsCallbacks {}

    impl Callbacks for WindowsCallbacks {
        type Error = Error;

        fn on_disconnect(&self, error: Option<&ConnlibError>) -> Result<(), Self::Error> {
            panic!("error recovery not implemented. Error: {error:?}");
        }

        fn on_error(&self, error: &ConnlibError) -> Result<(), Self::Error> {
            panic!("error recovery not implemented. Error: {error}");
        }
    }

    let callbacks = WindowsCallbacks::default();

    let _session = Session::connect(
        "https://api.firez.one/firezone",
        secrecy::SecretString::from_str("bogus_secret").unwrap(),
        "trisha-laptop-2023".to_string(),
        callbacks,
    );
}

#[cfg(target_os = "linux")]
mod tauri {
    pub fn main() {
        panic!("GUI not implemented for Linux.");
    }
}

#[cfg(target_os = "windows")]
mod tauri {
    use tauri::{
        CustomMenuItem, SystemTray, SystemTrayEvent, SystemTrayMenu, SystemTrayMenuItem,
        SystemTraySubmenu,
    };

    pub fn main() {
        let tray = SystemTray::new().with_menu(signed_out_menu());

        tauri::Builder::default()
            .invoke_handler(tauri::generate_handler![greet])
            .system_tray(tray)
            .on_system_tray_event(|app, event| {
                if let SystemTrayEvent::MenuItemClick { id, .. } = event {
                    match id.as_str() {
                        "/sign_in" => {
                            app.tray_handle()
                                .set_menu(signed_in_menu(
                                    "user@example.com",
                                    &[("CloudFlare", "1.1.1.1"), ("Google", "8.8.8.8")],
                                ))
                                .unwrap();
                        }
                        "/sign_out" => app.tray_handle().set_menu(signed_out_menu()).unwrap(),
                        "/about" => println!("About Firezone"),
                        "/settings" => {
                            app.tray_handle()
                                .set_menu(signed_in_menu(
                                    "user@example.com",
                                    &[
                                        ("CloudFlare", "1.1.1.1"),
                                        ("New resource", "127.0.0.1"),
                                        ("Google", "8.8.8.8"),
                                    ],
                                ))
                                .unwrap();
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
            .run(tauri::generate_context!())
            .expect("error while running tauri application");
    }

    // Learn more about Tauri commands at https://tauri.app/v1/guides/features/command
    #[tauri::command]
    fn greet(name: &str) -> String {
        format!("Hello, {}! You've been greeted from Rust!", name)
    }

    fn signed_in_menu(user_email: &str, resources: &[(&str, &str)]) -> SystemTrayMenu {
        let mut menu = SystemTrayMenu::new()
            .add_item(
                CustomMenuItem::new("".to_string(), format!("Signed in as {user_email}"))
                    .disabled(),
            )
            .add_item(CustomMenuItem::new("/sign_out".to_string(), "Sign out"))
            .add_native_item(SystemTrayMenuItem::Separator)
            .add_item(CustomMenuItem::new("".to_string(), "RESOURCES"));

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
            .add_item(
                CustomMenuItem::new("/quit".to_string(), "Quit Firezone").accelerator("Ctrl+Q"),
            );

        menu
    }

    fn signed_out_menu() -> SystemTrayMenu {
        SystemTrayMenu::new()
            .add_item(CustomMenuItem::new("/sign_in".to_string(), "Sign In"))
            .add_native_item(SystemTrayMenuItem::Separator)
            .add_item(CustomMenuItem::new("/about".to_string(), "About"))
            .add_item(CustomMenuItem::new("/settings".to_string(), "Settings"))
            .add_item(
                CustomMenuItem::new("/quit".to_string(), "Quit Firezone").accelerator("Ctrl+Q"),
            )
    }
}
