//! The Tauri-based GUI Client for Windows and Linux
//!
//! Most of this Client is stubbed out with panics on macOS.
//! The real macOS Client is in `swift/apple`

use crate::{
    auth,
    controller::{Controller, ControllerRequest, CtlrTx, Failure, GuiIntegration},
    deep_link,
    ipc::{self, ClientRead, ClientWrite, SocketId},
    logging::FileCount,
    settings::{
        self, AdvancedSettings, AdvancedSettingsLegacy, AdvancedSettingsViewModel, MdmSettings,
    },
    updates,
};
use anyhow::{Context, Result, bail};
use firezone_logging::err_with_src;
use firezone_telemetry::{Telemetry, analytics};
use futures::SinkExt as _;
use std::time::Duration;
use tauri::{Emitter, Manager};
use tokio::sync::mpsc;
use tokio_stream::StreamExt;
use tracing::instrument;

pub mod system_tray;

#[cfg(target_os = "linux")]
#[path = "gui/os_linux.rs"]
mod os;

#[cfg(target_os = "macos")]
#[path = "gui/os_macos.rs"]
mod os;

#[cfg(target_os = "windows")]
#[path = "gui/os_windows.rs"]
mod os;

pub use os::set_autostart;

/// All managed state that we might need to access from odd places like Tauri commands.
///
/// Note that this never gets Dropped because of
/// <https://github.com/tauri-apps/tauri/issues/8631>
pub(crate) struct Managed {
    pub ctlr_tx: CtlrTx,
    pub inject_faults: bool,
}

struct TauriIntegration {
    app: tauri::AppHandle,
    tray: system_tray::Tray,
}

impl TauriIntegration {
    fn main_window(&self) -> Result<tauri::WebviewWindow> {
        self.app
            .get_webview_window("main")
            .context("Couldn't get handle to window")
    }

    fn navigate(&self, path: &str) -> Result<()> {
        let window = self.main_window()?;

        let mut url = window.url()?;
        url.set_path(path);

        window.navigate(url)?;

        Ok(())
    }
}

impl Drop for TauriIntegration {
    fn drop(&mut self) {
        tracing::debug!("Instructing Tauri to exit");

        self.app.exit(0);
    }
}

impl GuiIntegration for TauriIntegration {
    fn notify_signed_in(&self, session: &auth::Session) -> Result<()> {
        self.app
            .emit("signed_in", session)
            .context("Failed to send `signed_in` event")?;

        Ok(())
    }

    fn notify_signed_out(&self) -> Result<()> {
        self.app
            .emit("signed_out", ())
            .context("Failed to send `signed_out` event")?;

        Ok(())
    }

    fn notify_settings_changed(
        &self,
        mdm_settings: MdmSettings,
        advanced_settings: AdvancedSettings,
    ) -> Result<()> {
        self.app
            .emit(
                "settings_changed",
                AdvancedSettingsViewModel::new(mdm_settings, advanced_settings),
            )
            .context("Failed to send `settings_changed` event")?;

        Ok(())
    }

    fn notify_logs_recounted(&self, file_count: &FileCount) -> Result<()> {
        self.app
            .emit("logs_recounted", file_count)
            .context("Failed to send `logs_recounted` event")?;

        Ok(())
    }

    fn open_url<P: AsRef<str>>(&self, url: P) -> Result<()> {
        tauri_plugin_opener::open_url(url, Option::<&str>::None)?;

        Ok(())
    }

    fn set_tray_icon(&mut self, icon: system_tray::Icon) {
        self.tray.set_icon(icon);
    }

    fn set_tray_menu(&mut self, app_state: system_tray::AppState) {
        self.tray.update(app_state)
    }

    fn show_notification(&self, title: &str, body: &str) -> Result<()> {
        os::show_notification(&self.app, title, body)
    }

    fn show_update_notification(&self, ctlr_tx: CtlrTx, title: &str, url: url::Url) -> Result<()> {
        os::show_update_notification(&self.app, ctlr_tx, title, url)
    }

    fn set_window_visible(&self, visible: bool) -> Result<()> {
        let win = self.main_window()?;

        if visible {
            // Needed to bring shown windows to the front
            // `request_user_attention` and `set_focus` don't work, at least on Linux
            win.hide()?;
            // Needed to show windows that are completely hidden
            win.show()?;
        } else {
            win.hide().context("Couldn't hide window")?;
        }

        Ok(())
    }

    fn show_overview_page(&self, current_session: Option<&auth::Session>) -> Result<()> {
        // Ensure state in frontend is up-to-date.
        match current_session {
            Some(session) => self.notify_signed_in(session)?,
            None => self.notify_signed_out()?,
        };
        self.navigate("overview")?;
        self.set_window_visible(true)?;

        Ok(())
    }

    fn show_settings_page(
        &self,
        mdm_settings: MdmSettings,
        advanced_settings: AdvancedSettings,
    ) -> Result<()> {
        self.notify_settings_changed(mdm_settings, advanced_settings)?; // Ensure settings are up to date in GUI.
        self.navigate("settings")?;
        self.set_window_visible(true)?;

        Ok(())
    }

    fn show_about_page(&self) -> Result<()> {
        self.navigate("about")?;
        self.set_window_visible(true)?;

        Ok(())
    }
}

pub struct RunConfig {
    pub inject_faults: bool,
    pub debug_update_check: bool,
    pub smoke_test: bool,
    pub no_deep_links: bool,
    pub quit_after: Option<u64>,
    pub fail_with: Option<Failure>,
}

/// IPC Messages that a newly launched instance (i.e. a client) may send to an already running instance of Firezone.
#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub enum ClientMsg {
    Deeplink(url::Url),
    NewInstance,
}

/// IPC Messages that an already running instance of Firezone may send to a newly launched instance.
#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub enum ServerMsg {
    Ack,
}

/// Runs the Tauri GUI and returns on exit or unrecoverable error
#[instrument(skip_all)]
pub fn run(
    rt: &tokio::runtime::Runtime,
    telemetry: &mut Telemetry,
    config: RunConfig,
    advanced_settings: AdvancedSettingsLegacy,
    reloader: firezone_logging::FilterReloadHandle,
) -> Result<()> {
    let mdm_settings = settings::load_mdm_settings()
        .inspect_err(|e| tracing::debug!("Failed to load MDM settings {e:#}"))
        .unwrap_or_default();

    let api_url = mdm_settings
        .api_url
        .as_ref()
        .unwrap_or(&advanced_settings.api_url);

    telemetry.start(
        api_url.as_str(),
        crate::RELEASE,
        firezone_telemetry::GUI_DSN,
    );

    // Get the device ID before starting Tokio, so that all the worker threads will inherit the correct scope.
    // Technically this means we can fail to get the device ID on a newly-installed system, since the Tunnel service may not have fully started up when the GUI process reaches this point, but in practice it's unlikely.
    if let Ok(id) = firezone_bin_shared::device_id::get() {
        Telemetry::set_firezone_id(id.id.clone());

        analytics::identify(id.id, api_url.to_string(), crate::RELEASE.to_owned());
    }

    // Needed for the deep link server
    tauri::async_runtime::set(rt.handle().clone());

    let _guard = rt.enter();

    let gui_ipc = match rt.block_on(create_gui_ipc_server()) {
        Ok(gui_ipc) => gui_ipc,
        Err(e) => {
            tracing::debug!("{e:#}");

            return Err(anyhow::Error::new(AlreadyRunning));
        }
    };

    let (general_settings, advanced_settings) =
        rt.block_on(settings::migrate_legacy_settings(advanced_settings));

    let (ctlr_tx, ctlr_rx) = mpsc::channel(5);
    let (ready_tx, mut ready_rx) = mpsc::channel::<tauri::AppHandle>(1);

    let managed = Managed {
        ctlr_tx: ctlr_tx.clone(),
        inject_faults: config.inject_faults,
    };

    let app = tauri::Builder::default()
        .manage(managed)
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                // Keep the frontend running but just hide this webview
                // Per https://tauri.app/v1/guides/features/system-tray/#preventing-the-app-from-closing
                // Closing the window fully seems to deallocate it or something.

                if let Err(e) = window.hide() {
                    tracing::warn!("Failed to hide window: {}", err_with_src(&e))
                };
                api.prevent_close();
            }
        })
        .invoke_handler(crate::view::generate_handler())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_opener::init())
        .build(tauri::generate_context!())
        .context("Failed to build Tauri app instance")?;

    // Spawn the setup task.
    // Everything we need to do once Tauri is fully initialised goes in here.
    let setup_task = rt.spawn(async move {
        // Block until Tauri is ready.
        let app_handle = ready_rx
            .recv()
            .await
            .context("Never received ready event from Tauri")?;

        let (updates_tx, updates_rx) = mpsc::channel(1);

        if mdm_settings.check_for_updates.is_none_or(|check| check) {
            // Check for updates
            tokio::spawn(async move {
                if let Err(error) = updates::checker_task(updates_tx, config.debug_update_check).await {
                    tracing::error!("Error in updates::checker_task: {error:#}");
                }
            });
        } else {
            tracing::info!("Update checker disabled via MDM");
        }

        if config.smoke_test {
            let ctlr_tx = ctlr_tx.clone();
            tokio::spawn(async move {
                if let Err(error) = smoke_test(ctlr_tx).await {
                    tracing::error!(
                        "Error during smoke test, crashing on purpose so a dev can see our stacktraces: {error:#}"
                    );
                    unsafe { sadness_generator::raise_segfault() }
                }
            });
        }

        tracing::debug!(config.no_deep_links);
        if !config.no_deep_links {
            // The single-instance check is done, so register our exe
            // to handle deep links
            let exe = tauri_utils::platform::current_exe().context("Can't find our own exe path")?;
            deep_link::register(exe).context("Failed to register deep link handler")?;
        }

        if let Some(failure) = config.fail_with {
            let ctlr_tx = ctlr_tx.clone();
            tokio::spawn(async move {
                let delay = 5;
                tracing::warn!(
                    "Will crash / error / panic on purpose in {delay} seconds to test error handling."
                );
                tokio::time::sleep(Duration::from_secs(delay)).await;
                tracing::warn!("Crashing / erroring / panicking on purpose");
                ctlr_tx.send(ControllerRequest::Fail(failure)).await?;
                Ok::<_, anyhow::Error>(())
            });
        }

        if let Some(delay) = config.quit_after {
            let ctlr_tx = ctlr_tx.clone();
            tokio::spawn(async move {
                tracing::warn!("Will quit gracefully in {delay} seconds.");
                tokio::time::sleep(Duration::from_secs(delay)).await;
                tracing::warn!("Quitting gracefully due to `--quit-after`");
                ctlr_tx
                    .send(ControllerRequest::SystemTrayMenu(system_tray::Event::Quit))
                    .await?;
                Ok::<_, anyhow::Error>(())
            });
        }

        assert_eq!(
            firezone_bin_shared::BUNDLE_ID,
            app_handle.config().identifier,
            "BUNDLE_ID should match bundle ID in tauri.conf.json"
        );

        let tray =
            system_tray::Tray::new(
                app_handle.clone(),
                |app, event| match handle_system_tray_event(app, event) {
                    Ok(_) => {}
                    Err(e) => tracing::error!("{e}"),
                },
            )?;
        let integration = TauriIntegration {
            app: app_handle,
            tray,
        };


        // Spawn the controller
        let ctrl_task = tokio::spawn(Controller::start(
            ctlr_tx,
            integration,
            ctlr_rx,
            general_settings,
            mdm_settings,
            advanced_settings,
            reloader,
            updates_rx,
            gui_ipc
        ));

        anyhow::Ok(ctrl_task)
    });

    // Run the Tauri app to completion, i.e. until `app_handle.exit(0)` is called.
    // This blocks the current thread!
    app.run_return(move |app_handle, event| {
        #[expect(
            clippy::wildcard_enum_match_arm,
            reason = "We only care about these two events from Tauri"
        )]
        match event {
            tauri::RunEvent::ExitRequested {
                    api, code: None, .. // `code: None` means the user closed the last window.
                } => {
                api.prevent_exit();
            }
            tauri::RunEvent::Ready => {
                // Notify our setup task that we are ready!
                let _ = ready_tx.try_send(app_handle.clone());
            }
            _ => (),
        }
    });

    // Wait until the controller task finishes.
    rt.block_on(async move {
        let ctrl_task = setup_task.await.context("Failed to complete app setup")??;
        let ctrl_or_timeout = tokio::time::timeout(Duration::from_secs(5), ctrl_task);

        ctrl_or_timeout
            .await
            .context("Controller failed to exit within 5s after OS-eventloop finished")?
            .context("Controller panicked")?
            .context("Controller failed")?;

        anyhow::Ok(())
    })?;

    tracing::info!("Controller exited gracefully");

    Ok(())
}

#[cfg(not(debug_assertions))]
async fn smoke_test(_: CtlrTx) -> Result<()> {
    bail!("Smoke test is not built for release binaries.");
}

/// Runs a smoke test and then asks Controller to exit gracefully
///
/// You can purposely fail this test by deleting the exported zip file during
/// the 10-second sleep.
#[cfg(debug_assertions)]
async fn smoke_test(ctlr_tx: CtlrTx) -> Result<()> {
    let delay = 10;
    tracing::info!("Will quit on purpose in {delay} seconds as part of the smoke test.");
    let quit_time = tokio::time::Instant::now() + Duration::from_secs(delay);

    // Test log exporting
    let path = std::path::PathBuf::from("smoke_test_log_export.zip");

    let stem = "connlib-smoke-test".into();
    match tokio::fs::remove_file(&path).await {
        Ok(()) => {}
        Err(error) => {
            if error.kind() != std::io::ErrorKind::NotFound {
                bail!("Error while removing old zip file")
            }
        }
    }
    ctlr_tx
        .send(ControllerRequest::ExportLogs {
            path: path.clone(),
            stem,
        })
        .await
        .context("Failed to send `ExportLogs` request")?;
    let (tx, rx) = tokio::sync::oneshot::channel();
    ctlr_tx
        .send(ControllerRequest::ClearLogs(tx))
        .await
        .context("Failed to send `ClearLogs` request")?;
    rx.await
        .context("Failed to await `ClearLogs` result")?
        .map_err(|s| anyhow::anyhow!(s))
        .context("`ClearLogs` failed")?;

    // Give the app some time to export the zip and reach steady state
    tokio::time::sleep_until(quit_time).await;

    // Write the settings so we can check the path for those
    settings::save_advanced(&AdvancedSettings::default()).await?;

    // Check results of tests
    let zip_len = tokio::fs::metadata(&path)
        .await
        .context("Failed to get zip file metadata")?
        .len();
    if zip_len <= 22 {
        bail!("Exported log zip just has the file header");
    }
    tokio::fs::remove_file(&path)
        .await
        .context("Failed to remove zip file")?;
    tracing::info!(?path, ?zip_len, "Exported log zip looks okay");

    // Check that settings file and at least one log file were written
    anyhow::ensure!(tokio::fs::try_exists(settings::advanced_settings_path()?).await?);

    tracing::info!("Quitting on purpose because of `smoke-test` subcommand");
    ctlr_tx
        .send(ControllerRequest::SystemTrayMenu(system_tray::Event::Quit))
        .await
        .context("Failed to send Quit request")?;

    Ok::<_, anyhow::Error>(())
}

fn handle_system_tray_event(app: &tauri::AppHandle, event: system_tray::Event) -> Result<()> {
    app.try_state::<Managed>()
        .context("can't get Managed struct from Tauri")?
        .ctlr_tx
        .blocking_send(ControllerRequest::SystemTrayMenu(event))?;
    Ok(())
}

#[derive(Debug, thiserror::Error)]
#[error("Another instance of Firezone is already running")]
pub struct AlreadyRunning;

#[derive(Debug, thiserror::Error)]
#[error("Failed to communicate with existing Firezone instance")]
pub struct NewInstanceHandshakeFailed(anyhow::Error);

/// Create a new instance of the GUI IPC server.
///
/// Every time Firezone gets launched, we attempt to connect to this server.
/// If we can successfully connect and handshake a message, then we know that there is a functioning instance of Firezone already running.
///
/// If we hit an IO errors during the connection, we assume that there isn't already an instance of Firezone and we consider us to be the first instance.
///
/// There is a third, somewhat gnarly case:
///
/// An instance of Firezone may already be running but it is not responding.
/// Launching another instance on top of it would likely create more problems that it solves, so we also need to fail for that case.
async fn create_gui_ipc_server() -> Result<ipc::Server> {
    let (read, write) = match ipc::connect::<ServerMsg, ClientMsg>(
        SocketId::Gui,
        ipc::ConnectOptions { num_attempts: 1 },
    )
    .await
    {
        Ok(pair) => pair,
        Err(e) => {
            // If we can't connect to the socket, we must be the first instance.
            tracing::debug!(
                "We appear to be the first instance of the GUI client; connecting to socket yielded: {e:#}"
            );

            return ipc::Server::new(SocketId::Gui).context("Failed to create GUI IPC socket");
        }
    };

    tokio::time::timeout(Duration::from_secs(5), new_instance_handshake(read, write))
        .await
        .context("Failed to handshake with existing instance in 5s")
        .map_err(NewInstanceHandshakeFailed)?
        .map_err(NewInstanceHandshakeFailed)?;

    // If we managed to send the IPC message then another instance of Firezone is already running.

    bail!("Successfully handshaked with existing instance of Firezone GUI")
}

async fn new_instance_handshake(
    mut read: ClientRead<ServerMsg>,
    mut write: ClientWrite<ClientMsg>,
) -> Result<()> {
    write.send(&ClientMsg::NewInstance).await?;
    let response = read
        .next()
        .await
        .context("No response received")?
        .context("Failed to receive response")?;

    anyhow::ensure!(response == ServerMsg::Ack);

    Ok(())
}
