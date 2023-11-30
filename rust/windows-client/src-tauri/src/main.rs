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

    println!("printing to stdout");

    let cli = Cli::parse();

    match &cli.command {
        None | Some(Cmd::Tauri) => details::main_tauri(),
        Some(Cmd::Debug) => {
            println!("debug");
            Ok(())
        }
        Some(Cmd::DebugAuth) => details::main_debug_auth(),
        Some(Cmd::DebugConnlib) => main_debug_connlib(cli),
        Some(Cmd::DebugDeviceId) => main_debug_device_id(),
        Some(Cmd::DebugLocalServer) => main_debug_local_server(),
        Some(Cmd::DebugWintun) => details::main_debug_wintun(),
    }
}

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Option<CliCommands>,

    #[command(flatten)]
    common: CommonArgs,

    /// File logging directory. Should be a path that's writeable by the current user.
    #[arg(short, long, env = "LOG_DIR")]
    log_dir: Option<PathBuf>,
}

#[derive(clap::Subcommand)]
enum CliCommands {
    Debug,
    DebugAuth,
    DebugConnlib,
    DebugDeviceId,
    DebugLocalServer,
    DebugWintun,
    Tauri,
}

fn main_debug_connlib(cli: Cli) -> Result<()> {
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

    let (layer, handle) = cli.log_dir.as_deref().map(file_logger::layer).unzip();
    setup_global_subscriber(layer);

    // TODO: If the ID should be either smbios ID or hashed MAC,
    // we should use a pepper for the hash and also do that for the smbios ID, right? Is there already a crypto lib in our dependencies like sodium that has salted / peppered hashes?

    let data = smbioslib::table_load_from_device()?;
    let device_id = if let Some(uuid) = data.find_map(|sys_info: SysInfo| sys_info.uuid()) {
        tracing::info!("smbioslib got UUID");
        uuid.to_string()
    } else {
        tracing::error!("smbioslib couldn't find UUID, making a random device ID");
        uuid::Uuid::new_v4().to_string()
    };

    let mut session = Session::connect(
        cli.common.api_url,
        SecretString::from(cli.common.token),
        device_id,
        CallbackHandler { handle },
    )
    .unwrap();

    tracing::info!("new_session");

    block_on_ctrl_c();

    session.disconnect(None);
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

fn main_debug_local_server() -> Result<()> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
    let local_addr = listener.local_addr()?;
    println!("Listening on {local_addr}");

    // The exe is a GUI app so Powershell may not show the stdout/stderr
    // Just launch the GUI as feedback.

    details::main_tauri()?;

    Ok(())
}

#[cfg(target_os = "linux")]
mod details {
    use super::*;

    pub fn main_tauri() -> Result<()> {
        panic!("GUI not implemented for Linux.");
    }

    pub fn main_debug_auth() -> Result<()> {
        unimplemented!();
    }

    pub fn main_debug_wintun() -> Result<()> {
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

    pub fn main_debug_auth() -> Result<()> {
        sign_in()
    }

    pub fn main_tauri() -> Result<()> {
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
                            // TODO: Don't block the main thread here
                            sign_in().unwrap();

                            app.tray_handle()
                                .set_menu(signed_in_menu(
                                    "user@example.com",
                                    &[("CloudFlare", "1.1.1.1"), ("Google", "8.8.8.8")],
                                ))
                                .unwrap();
                        }
                        "/sign_out" => app.tray_handle().set_menu(signed_out_menu()).unwrap(),
                        "/about" => {
                            let win = app.get_window("main-window").unwrap();

                            if win.is_visible().unwrap() {
                                // If we close the window here, we can't re-open it, we'd have to fully re-create it. Not needed for MVP - We agreed 100 MB is fine for the GUI client.
                                win.hide().unwrap();
                            } else {
                                win.show().unwrap();
                            }
                        }
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
            .build(tauri::generate_context!())
            .expect("error while building tauri application")
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
        use windows::{
            core::HSTRING,
            Foundation::{AsyncStatus, Uri},
            Security::Authentication::Web::WebAuthenticationBroker,
        };

        let start_uri = HSTRING::from("https://app.firez.one/firezone?client_platform=windows");
        let start_uri = Uri::CreateUri(&start_uri)?;

        println!("Kicking off async call...");
        let future = WebAuthenticationBroker::AuthenticateSilentlyAsync(&start_uri)?;

        for i in 0..600 {
            println!("Waiting for auth broker ({i})...");
            std::thread::sleep(std::time::Duration::from_secs(1));
            match future.Status()? {
                AsyncStatus::Completed => {
                    let end_uri = future.get().unwrap().ResponseData()?;
                    println!("End URI: {end_uri}");
                    break;
                }
                AsyncStatus::Started => {}
                status => panic!("Async failed: {status:?}"),
            }
        }
        Ok(())
    }

    pub fn main_debug_wintun() -> Result<()> {
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

        // Powershell won't show stdout/stderr so for certain tests use the GUI as a "return 0" signal to the dev
        main_tauri()?;

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
