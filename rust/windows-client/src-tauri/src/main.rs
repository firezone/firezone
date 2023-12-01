// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use anyhow::Result;
use clap::Parser;
use connlib_client_shared::{file_logger, Callbacks, Error, Session};
use firezone_cli_utils::{block_on_ctrl_c, setup_global_subscriber, CommonArgs};
use secrecy::SecretString;
use std::path::PathBuf;

fn main() -> Result<()> {
    use CliCommands as Cmd;

    change_to_well_known_dir()?;

    // Special case for app link URIs
    if let Some(arg) = std::env::args().nth(1) {
        if arg.starts_with("firezone://") {
            return details::main_tauri(None, Some(arg));
        }
    }

    let cli = Cli::parse();

    match cli.command {
        None => details::main_tauri(None, None),
        Some(Cmd::Tauri { common }) => details::main_tauri(common, None),
        Some(Cmd::Debug) => {
            println!("debug");
            Ok(())
        }
        Some(Cmd::DebugAuth) => details::main_debug_auth(),
        Some(Cmd::DebugConnlib { common }) => main_debug_connlib(common),
        Some(Cmd::DebugCredentials) => main_debug_credentials(),
        Some(Cmd::DebugDeviceId) => main_debug_device_id(),
        Some(Cmd::DebugWintun) => details::main_debug_wintun(cli),
    }
}

/// Change dir to the app's local data dir. This prevents issues with the logger trying to write to C:\Windows\System32 when Firefox / Chrome launchs us in that dir.

fn change_to_well_known_dir() -> Result<()> {
    let project_dirs = directories::ProjectDirs::from("", "Firezone", "Client").unwrap();
    let working_dir = project_dirs.data_local_dir();
    std::fs::create_dir_all(working_dir)?;
    std::env::set_current_dir(working_dir)?;
    Ok(())
}

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
pub(crate) struct Cli {
    #[command(subcommand)]
    command: Option<CliCommands>,
}

#[derive(clap::Subcommand)]
enum CliCommands {
    Debug,
    DebugAuth,
    DebugConnlib {
        #[command(flatten)]
        common: CommonArgs,
    },
    DebugCredentials,
    DebugDeviceId,
    DebugWintun,
    Tauri {
        // Common args are optional for the GUI because most of the time it'll be launched with useful args or env vars
        #[command(flatten)]
        common: Option<CommonArgs>,
    },
}

fn main_debug_connlib(common_args: CommonArgs) -> Result<()> {
    use connlib_client_shared::ResourceDescription;
    use smbioslib::SMBiosSystemInformation as SysInfo;

    #[derive(Clone)]
    struct CallbackHandler {
        handle: Option<file_logger::Handle>,
    }

    impl Callbacks for CallbackHandler {
        type Error = std::convert::Infallible;

        fn on_disconnect(&self, error: Option<&Error>) -> Result<(), Self::Error> {
            tracing::error!("on_disconnect not implemented. Error: {error:?}");
            Ok(())
        }

        fn on_error(&self, error: &Error) -> Result<(), Self::Error> {
            tracing::error!("on_error not implemented. Error: {error}");
            Ok(())
        }

        fn on_update_resources(
            &self,
            _resource_list: Vec<ResourceDescription>,
        ) -> Result<(), Self::Error> {
            tracing::error!("on_update_resources not implemented");
            Ok(())
        }

        fn roll_log_file(&self) -> Option<PathBuf> {
            self.handle
                .as_ref()?
                .roll_to_new_file()
                .unwrap_or_else(|e| {
                    tracing::debug!("Failed to roll over to new file: {e}");
                    let _ = self.on_error(&Error::LogFileRollError(e));

                    None
                })
        }
    }

    let (layer, handle) = file_logger::layer(std::path::Path::new("."));
    setup_global_subscriber(layer);

    // TODO: Is the SHA256 only intended to make the device ID fixed-length, or is it supposed to obfuscate the ID too? If so, we could add a pepper to defeat rainbow tables.

    let data = smbioslib::table_load_from_device()?;
    let device_id = if let Some(uuid) = data.find_map(|sys_info: SysInfo| sys_info.uuid()) {
        tracing::info!("smbioslib got UUID");
        uuid.to_string()
    } else {
        tracing::error!("smbioslib couldn't find UUID, making a random device ID");
        uuid::Uuid::new_v4().to_string()
    };

    let mut session = Session::connect(
        common_args.api_url,
        SecretString::from(common_args.token),
        device_id,
        CallbackHandler {
            handle: Some(handle),
        },
    )
    .unwrap();

    tracing::info!("new_session");

    block_on_ctrl_c();

    session.disconnect(None);
    Ok(())
}

fn main_debug_credentials() -> Result<()> {
    use keyring::Entry;

    // TODO: Remove placeholder email
    let entry = Entry::new_with_target("token", "firezone_windows_client", "username@example.com")?;
    match entry.get_password() {
        Ok(password) => {
            println!("Placeholder password is '{password}'");

            println!("Deleting password");
            entry.delete_password()?;
        }
        Err(keyring::Error::NoEntry) => {
            println!("No password in credential manager");

            let new_password = "top_secret_password";
            println!("Setting password to {new_password}");
            entry.set_password(new_password)?;
        }
        Err(e) => return Err(e.into()),
    }

    Ok(())
}

fn main_debug_device_id() -> Result<()> {
    use smbioslib::SMBiosSystemInformation as SysInfo;

    let data = smbioslib::table_load_from_device()?;
    if let Some(uuid) = data.find_map(|sys_info: SysInfo| sys_info.uuid()) {
        println!("SMBios uuid: {uuid}");
    } else {
        println!("SMBios couldn't find uuid");
    }

    Ok(())
}

#[cfg(target_os = "linux")]
mod details {
    use super::*;

    pub(crate) fn main_tauri(_: Option<CommonArgs>, _: Option<String>) -> Result<()> {
        panic!("GUI not implemented for Linux.");
    }

    pub(crate) fn main_debug_auth() -> Result<()> {
        unimplemented!();
    }

    pub(crate) fn main_debug_wintun(_: Cli) -> Result<()> {
        panic!("Wintun not implemented for Linux.");
    }
}

#[cfg(target_os = "windows")]
mod details {
    use super::*;
    use tauri::{
        CustomMenuItem, Manager, SystemTray, SystemTrayEvent, SystemTrayMenu, SystemTrayMenuItem,
        SystemTraySubmenu,
    };

    pub(crate) fn main_debug_auth() -> Result<()> {
        sign_in()
    }

    // TODO: Decide whether Windows needs to handle env vars and CLI args for IDs / tokens
    pub(crate) fn main_tauri(_: Option<CommonArgs>, app_link: Option<String>) -> Result<()> {
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

    fn sign_in() -> Result<()> {
        // TODO: Real CSRF token.
        //
        open::that("https://app.firez.one/firezone?client_csrf_token=bogus&client_platform=apple")?;
        Ok(())
    }

    pub(crate) fn main_debug_wintun(_: Cli) -> Result<()> {
        use std::sync::Arc;

        //Must be run as Administrator because we create network adapters
        //Load the wintun dll file so that we can call the underlying C functions
        //Unsafe because we are loading an arbitrary dll file
        let wintun = unsafe { wintun::load_from_path("./wintun.dll") }?;

        //Try to open an adapter with the name "Demo"
        let adapter = match wintun::Adapter::open(&wintun, "Demo") {
            Ok(a) => a,
            Err(_) => {
                //If loading failed (most likely it didn't exist), create a new one
                wintun::Adapter::create(&wintun, "Demo", "Example manor hatch stash", None)?
            }
        };
        //Specify the size of the ring buffer the wintun driver should use.
        let session = Arc::new(adapter.start_session(wintun::MAX_RING_CAPACITY)?);

        //Get a 20 byte packet from the ring buffer
        let mut packet = session.allocate_send_packet(20)?;
        let bytes: &mut [u8] = packet.bytes_mut();
        //Write IPV4 version and header length
        bytes[0] = 0x40;

        //Finish writing IP header
        bytes[9] = 0x69;
        bytes[10] = 0x04;
        bytes[11] = 0x20;
        //...

        //Send the packet to wintun virtual adapter for processing by the system
        session.send_packet(packet);

        //Stop any readers blocking for data on other threads
        //Only needed when a blocking reader is preventing shutdown Ie. it holds an Arc to the
        //session, blocking it from being dropped
        session.shutdown()?;

        //the session is stopped on drop
        //drop(session);

        //drop(adapter)
        //And the adapter closes its resources when dropped

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
                CustomMenuItem::new("".to_string(), format!("Signed in as {user_email}"))
                    .disabled(),
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
