//! The Tauri-based GUI Client for Windows and Linux
//!
//! Most of this Client is stubbed out with panics on macOS.
//! The real macOS Client is in `swift/apple`

use crate::client::{
    self, about, logging,
    settings::{self},
};
use anyhow::{Context, Result, bail};
use common::system_tray::Event as TrayMenuEvent;
use firezone_gui_client_common::{
    self as common,
    controller::{Controller, ControllerRequest, CtlrTx, GuiIntegration},
    deep_link,
    settings::AdvancedSettings,
    updates,
};
use firezone_logging::err_with_src;
use firezone_telemetry as telemetry;
use secrecy::{ExposeSecret as _, SecretString};
use std::{str::FromStr, time::Duration};
use tauri::Manager;
use tokio::sync::mpsc;
use tracing::instrument;

pub(crate) mod system_tray;

#[cfg(target_os = "linux")]
#[path = "gui/os_linux.rs"]
mod os;

// Stub only
#[cfg(target_os = "macos")]
#[path = "gui/os_macos.rs"]
#[expect(clippy::unnecessary_wraps)]
mod os;

#[cfg(target_os = "windows")]
#[path = "gui/os_windows.rs"]
mod os;

pub(crate) use os::set_autostart;

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

impl Drop for TauriIntegration {
    fn drop(&mut self) {
        tracing::debug!("Instructing Tauri to exit");

        self.app.exit(0);
    }
}

impl GuiIntegration for TauriIntegration {
    fn set_welcome_window_visible(&self, visible: bool) -> Result<()> {
        let win = self
            .app
            .get_webview_window("welcome")
            .context("Couldn't get handle to Welcome window")?;

        if visible {
            win.show().context("Couldn't show Welcome window")?;
        } else {
            win.hide().context("Couldn't hide Welcome window")?;
        }
        Ok(())
    }

    fn open_url<P: AsRef<str>>(&self, url: P) -> Result<()> {
        tauri_plugin_opener::open_url(url, Option::<&str>::None)?;

        Ok(())
    }

    fn set_tray_icon(&mut self, icon: common::system_tray::Icon) {
        self.tray.set_icon(icon);
    }

    fn set_tray_menu(&mut self, app_state: common::system_tray::AppState) {
        self.tray.update(app_state)
    }

    fn show_notification(&self, title: &str, body: &str) -> Result<()> {
        os::show_notification(&self.app, title, body)
    }

    fn show_update_notification(&self, ctlr_tx: CtlrTx, title: &str, url: url::Url) -> Result<()> {
        os::show_update_notification(&self.app, ctlr_tx, title, url)
    }

    fn show_window(&self, window: common::system_tray::Window) -> Result<()> {
        let id = match window {
            common::system_tray::Window::About => "about",
            common::system_tray::Window::Settings => "settings",
        };

        let win = self
            .app
            .get_webview_window(id)
            .context("Couldn't get handle to `{id}` window")?;

        // Needed to bring shown windows to the front
        // `request_user_attention` and `set_focus` don't work, at least on Linux
        win.hide()?;
        // Needed to show windows that are completely hidden
        win.show()?;
        Ok(())
    }
}

/// Runs the Tauri GUI and returns on exit or unrecoverable error
#[instrument(skip_all)]
pub(crate) fn run(
    cli: client::Cli,
    advanced_settings: AdvancedSettings,
    reloader: firezone_logging::FilterReloadHandle,
    mut telemetry: telemetry::Telemetry,
) -> Result<()> {
    // Needed for the deep link server
    let rt = tokio::runtime::Runtime::new().context("Couldn't start Tokio runtime")?;
    let _guard = rt.enter();

    // Make sure we're single-instance
    // We register our deep links to call the `open-deep-link` subcommand,
    // so if we're at this point, we know we've been launched manually
    let deep_link_server = rt.block_on(deep_link::Server::new())?;

    let (ctlr_tx, ctlr_rx) = mpsc::channel(5);
    let (updates_tx, updates_rx) = mpsc::channel(1);

    let managed = Managed {
        ctlr_tx: ctlr_tx.clone(),
        inject_faults: cli.inject_faults,
    };

    let (handle_tx, handle_rx) = tokio::sync::oneshot::channel();

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
        .invoke_handler(tauri::generate_handler![
            about::get_cargo_version,
            about::get_git_version,
            logging::clear_logs,
            logging::count_logs,
            logging::export_logs,
            settings::apply_advanced_settings,
            settings::reset_advanced_settings,
            settings::get_advanced_settings,
            crate::client::welcome::sign_in,
        ])
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_opener::init())
        .setup(move |app| {
            // Check for updates
            tokio::spawn(async move {
                if let Err(error) = updates::checker_task(updates_tx, cli.debug_update_check).await
                {
                    tracing::error!("Error in updates::checker_task: {error:#}");
                }
            });

            if let Some(client::Cmd::SmokeTest) = &cli.command {
                let ctlr_tx = ctlr_tx.clone();
                tokio::spawn(async move {
                    if let Err(error) = smoke_test(ctlr_tx).await {
                        tracing::error!("Error during smoke test, crashing on purpose so a dev can see our stacktraces: {error:#}");
                        unsafe { sadness_generator::raise_segfault() }
                    }
                });
            }

            tracing::debug!(cli.no_deep_links);
            if !cli.no_deep_links {
                // The single-instance check is done, so register our exe
                // to handle deep links
                let exe = tauri_utils::platform::current_exe().context("Can't find our own exe path")?;
                deep_link::register(exe).context("Failed to register deep link handler")?;
                tokio::spawn(accept_deep_links(deep_link_server, ctlr_tx.clone()));
            }

            if let Some(failure) = cli.fail_on_purpose() {
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

            if let Some(delay) = cli.quit_after {
                let ctlr_tx = ctlr_tx.clone();
                tokio::spawn(async move {
                    tracing::warn!("Will quit gracefully in {delay} seconds.");
                    tokio::time::sleep(Duration::from_secs(delay)).await;
                    tracing::warn!("Quitting gracefully due to `--quit-after`");
                    ctlr_tx.send(ControllerRequest::SystemTrayMenu(firezone_gui_client_common::system_tray::Event::Quit)).await?;
                    Ok::<_, anyhow::Error>(())
                });
            }

            assert_eq!(
                firezone_bin_shared::BUNDLE_ID,
                app.handle().config().identifier,
                "BUNDLE_ID should match bundle ID in tauri.conf.json"
            );

            let tray = system_tray::Tray::new(app.handle().clone(), |app, event| match handle_system_tray_event(app, event) {
                Ok(_) => {}
                Err(e) => tracing::error!("{e}"),
            })?;
            let integration = TauriIntegration { app: app.handle().clone(), tray };

            // Spawn the controller
            let ctrl_task = tokio::spawn(Controller::start(
                ctlr_tx,
                integration,
                ctlr_rx,
                advanced_settings,
                reloader,
                updates_rx,
            ));

            // Send the handle to the controller task back to the main thread.
            // If the receiver is gone, we don't care.
            let _ = handle_tx.send(ctrl_task);

            Ok(())
        })
        .build(tauri::generate_context!())
        .context("Failed to build Tauri app instance")?;

    // Run the Tauri app to completion, i.e. until `app_handle.exit(0)` is called.
    app.run_return(|_app_handle, event| {
        if let tauri::RunEvent::ExitRequested {
            api, code: None, .. // `code: None` means the user closed the last window.
        } = event
        {
            // Don't exit if we close our main window
            // https://tauri.app/v1/guides/features/system-tray/#preventing-the-app-from-closing
            api.prevent_exit();
        }
    });

    // Wait until the controller task finishes.
    rt.block_on(async move {
        let ctrl_task = handle_rx.await.context("Failed to complete setup hook")?;
        let ctrl_or_timeout = tokio::time::timeout(Duration::from_secs(5), ctrl_task);

        ctrl_or_timeout
            .await
            .context("Controller failed to exit within 5s after OS-eventloop finished")?
            .context("Controller panicked")?
            .context("Controller failed")?;

        anyhow::Ok(())
    })
    .inspect_err(|_| rt.block_on(telemetry.stop_on_crash()))?;

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
    common::settings::save(&AdvancedSettings::default()).await?;

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
    anyhow::ensure!(tokio::fs::try_exists(common::settings::advanced_settings_path()?).await?);

    tracing::info!("Quitting on purpose because of `smoke-test` subcommand");
    ctlr_tx
        .send(ControllerRequest::SystemTrayMenu(TrayMenuEvent::Quit))
        .await
        .context("Failed to send Quit request")?;

    Ok::<_, anyhow::Error>(())
}

/// Worker task to accept deep links from a named pipe forever
///
/// * `server` An initial named pipe server to consume before making new servers. This lets us also use the named pipe to enforce single-instance
async fn accept_deep_links(mut server: deep_link::Server, ctlr_tx: CtlrTx) -> Result<()> {
    loop {
        match server.accept().await {
            Ok(Some(bytes)) => {
                let url = SecretString::from_str(
                    std::str::from_utf8(bytes.expose_secret())
                        .context("Incoming deep link was not valid UTF-8")?,
                )
                .context("Impossible: can't wrap String into SecretString")?;
                // Ignore errors from this, it would only happen if the app is shutting down, otherwise we would wait
                ctlr_tx
                    .send(ControllerRequest::SchemeRequest(url))
                    .await
                    .ok();
            }
            Ok(None) => {
                tracing::debug!("Accepted deep-link but read 0 bytes, trying again ...");
            }
            Err(error) => {
                tracing::warn!("Failed to accept deep link: {error:#}")
            }
        }
        // We re-create the named pipe server every time we get a link, because of an oddity in the Windows API.
        server = deep_link::Server::new().await?;
    }
}

fn handle_system_tray_event(app: &tauri::AppHandle, event: TrayMenuEvent) -> Result<()> {
    app.try_state::<Managed>()
        .context("can't get Managed struct from Tauri")?
        .ctlr_tx
        .blocking_send(ControllerRequest::SystemTrayMenu(event))?;
    Ok(())
}
