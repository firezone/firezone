//! The GUI Client for Windows and Linux
//!
//! Most of this Client is stubbed out with panics on macOS.
//! The real macOS Client is in `swift/apple`

use crate::{
    controller::{Controller, ControllerRequest, Failure, GuiIntegration},
    deep_link,
    launch_lock::{self, FirstInstance, LaunchLock},
    logging::FileCount,
    settings::{
        self, AdvancedSettings, DeveloperSettings, DeveloperSettingsViewModel, GeneralSettings,
        GeneralSettingsViewModel, LogFilterViewModel, MdmSettings, SignInSettings,
    },
    ui::{self, Page, Ui, ViewModel},
    updates,
    view::{SessionViewModel, X509Certificate},
};
use anyhow::{Context, Result, bail};
use client_ipc::{self as ipc, ClientRead, ClientWrite, SocketId};
use freya::{
    prelude::*,
    winit::{event_loop::EventLoop, window::WindowId},
};
use futures::SinkExt as _;
use gui_ipc::{ClientMsg, ServerMsg};
use std::time::Duration;
use tokio::{runtime::Runtime, sync::mpsc};
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

const WINDOW_ICON: &[u8] = include_bytes!("../icons/128x128.png");

pub(crate) struct FreyaIntegration {
    tray: system_tray::Tray,
    /// Declared after `tray`, so the tray is removed before the event loop exits.
    gui: Gui,
}

/// The GUI thread, which runs Freya's event loop.
#[derive(Clone)]
struct Gui(LaunchHandle);

impl Gui {
    /// Runs `f` on the GUI thread.
    ///
    /// Requires `Send` because the closure crosses threads, which `LaunchHandle` does not check.
    fn post(&self, f: impl FnOnce(&mut RendererContext) + Send + 'static) {
        drop(self.0.post_callback(f));
    }

    fn update(&self, f: impl FnOnce(&mut ViewModel) + Send + 'static) {
        self.post(|ctx| {
            let mut ui = ctx.global_contexts.get_context::<Ui>();
            f(&mut ui.view_model.write());
        });
    }

    fn show(&self, page: Option<Page>) {
        self.post(move |ctx| {
            let mut ui = ctx.global_contexts.get_context::<Ui>();
            if let Some(page) = page {
                ui.page.set(page);
            }

            if let Some(window) = ctx.windows().values().next() {
                let window = window.window();
                window.set_visible(true);
                window.focus_window();
                return;
            }

            ctx.launch_window(window_config());
        });
    }

    fn close(&self) {
        self.post(|ctx| {
            let ids = ctx.windows().keys().copied().collect::<Vec<WindowId>>();
            for id in ids {
                Platform::get().close_window(id);
            }
        });
    }
}

impl Drop for Gui {
    fn drop(&mut self) {
        tracing::debug!("Instructing the GUI to exit");

        self.post(|ctx| ctx.exit());
    }
}

fn window_config() -> WindowConfig {
    WindowConfig::new(ui::app)
        .with_size(ui::WINDOW_SIZE.0, ui::WINDOW_SIZE.1)
        .with_title("Firezone")
        .with_app_id("firezone-client-gui")
        .with_icon(LaunchConfig::window_icon(WINDOW_ICON))
        .with_decorations(false)
        .with_resizable(false)
}

impl GuiIntegration for FreyaIntegration {
    fn notify_session_changed(&self, session: &SessionViewModel) -> Result<()> {
        let session = session.clone();
        self.gui
            .update(|view_model| view_model.session = Some(session));

        Ok(())
    }

    fn notify_settings_changed(
        &self,
        mdm_settings: MdmSettings,
        general_settings: GeneralSettings,
        advanced_settings: AdvancedSettings,
        signed_in_with: Option<SignInSettings>,
    ) -> Result<()> {
        let general_settings = GeneralSettingsViewModel::new(
            mdm_settings.clone(),
            general_settings,
            advanced_settings.clone(),
            signed_in_with,
        );
        let log_filter = LogFilterViewModel::new(mdm_settings, advanced_settings);
        self.gui.update(|view_model| {
            view_model.general_settings = Some(general_settings);
            view_model.log_filter = Some(log_filter);
        });

        Ok(())
    }

    fn notify_developer_settings_changed(
        &self,
        settings: DeveloperSettingsViewModel,
    ) -> Result<()> {
        self.gui
            .update(move |view_model| view_model.developer_settings = Some(settings));

        Ok(())
    }

    fn notify_logs_recounted(&self, file_count: &FileCount) -> Result<()> {
        let file_count = file_count.clone();
        self.gui
            .update(|view_model| view_model.log_count = Some(file_count));

        Ok(())
    }

    fn notify_device_trust_changed(
        &self,
        certificate: Option<&x509_keystore::ParsedCertificate>,
    ) -> Result<()> {
        let certificate = certificate.map(X509Certificate::from);
        self.gui
            .update(|view_model| view_model.certificate = certificate);

        Ok(())
    }

    fn open_url<P: AsRef<str>>(&self, url: P) -> Result<()> {
        open::that_detached(url.as_ref())
            .with_context(|| format!("Failed to open `{}`", url.as_ref()))?;

        Ok(())
    }

    fn set_tray_icon(&mut self, icon: system_tray::Icon) {
        self.tray.set_icon(icon);
    }

    fn set_tray_menu(&mut self, app_state: system_tray::AppState) {
        self.tray.update(app_state)
    }

    fn open_tray_menu(&self) -> Result<()> {
        self.tray.open_menu()
    }

    fn close_tray_menu(&self) -> Result<()> {
        self.tray.close_menu()
    }

    fn show_notification(&self, title: impl Into<String>, body: impl Into<String>) -> Result<()> {
        spawn_notification(title.into(), body.into(), None);

        Ok(())
    }

    fn show_update_notification(&self, release: updates::Release) -> Result<()> {
        spawn_notification(
            format!("Firezone {} available for download", release.version),
            "Click here to download the new version".to_owned(),
            Some(release.download_url),
        );

        Ok(())
    }

    fn set_window_visible(&self, visible: bool) -> Result<()> {
        if visible {
            self.gui.show(None);
        } else {
            self.gui.close();
        }

        Ok(())
    }

    fn show_overview_page(&self, session: &SessionViewModel) -> Result<()> {
        self.notify_session_changed(session)?;
        self.gui.show(Some(Page::Overview));

        Ok(())
    }

    fn show_settings_page(
        &self,
        mdm_settings: MdmSettings,
        general_settings: GeneralSettings,
        advanced_settings: AdvancedSettings,
        signed_in_with: Option<SignInSettings>,
    ) -> Result<()> {
        self.notify_settings_changed(
            mdm_settings,
            general_settings,
            advanced_settings,
            signed_in_with,
        )?;
        self.gui.show(Some(Page::Settings));

        Ok(())
    }

    fn show_about_page(&self) -> Result<()> {
        self.gui.show(Some(Page::About));

        Ok(())
    }

    async fn save_general_settings(&self, settings: &GeneralSettings) -> Result<()> {
        settings::save_general(settings).await?;

        Ok(())
    }

    async fn save_developer_settings(&self, settings: DeveloperSettings) -> Result<()> {
        settings::save_developer(settings).await?;

        Ok(())
    }
}

pub struct RunConfig {
    pub inject_faults: bool,
    pub debug_update_check: bool,
    pub smoke_test: bool,
    pub no_deep_links: bool,
    pub telemetry_allowed: bool,
    pub quit_after: Option<u64>,
    pub fail_with: Option<Failure>,
}

/// Shows a notification without blocking the caller.
///
/// Notifications are fire-and-forget: failures are only logged because
/// there is nothing the caller could do about them.
fn spawn_notification(title: String, body: String, open_url: Option<url::Url>) {
    let app_id = os::notification_app_id();

    tokio::spawn(async move {
        match desktop_notifications::show(&app_id, &title, &body, open_url.as_ref()).await {
            Ok(()) => tracing::debug!(%title, %body, "Showed notification"),
            Err(e) => tracing::debug!(%title, "Failed to show notification: {e:#}"),
        }
    });
}

/// Runs the GUI and returns on exit or unrecoverable error
#[instrument(skip_all)]
pub fn run(rt: &Runtime, config: RunConfig, reloader: logging::FilterReloadHandle) -> Result<()> {
    #[cfg(not(debug_assertions))]
    crate::package_identity::ensure_package_identity()?;

    let (gui_ipc, _launch_lock) = match rt.block_on(establish_single_instance())? {
        SingleInstance::First { server, lock } => (server, lock),
        SingleInstance::SecondHandedOff => bail!(AlreadyRunning),
    };

    let general_settings = settings::load_general_settings().unwrap_or_default();
    let developer_settings = settings::load_developer_settings().unwrap_or_default();

    let (ctlr_tx, ctlr_rx) = mpsc::channel(5);
    let tray_tx = ctlr_tx.clone();
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel::<LaunchHandle>();

    let ui = Ui::new(
        ui::Requests {
            tx: ctlr_tx.clone(),
            rt: rt.handle().clone(),
            inject_faults: config.inject_faults,
        },
        ui::Build {
            version: env!("CARGO_PKG_VERSION"),
            git_sha: git_sha::git_sha().unwrap_or("0000000000000000000000000000000000000000"),
        },
    );

    // Spawn the setup task.
    // Everything we need to do once the GUI event loop runs goes in here.
    let setup_task = rt.spawn(async move {
        // Dropping it on any error below exits the event loop.
        let gui = Gui(ready_rx
            .await
            .context("Never received ready event from the GUI")?);

        let (updates_tx, updates_rx) = mpsc::channel(1);

        // The checker always runs; the controller enforces the `checkForUpdates`
        // MDM policy once it receives the authoritative settings over IPC.
        tokio::spawn(async move {
            let Err(error) = updates::checker_task(updates_tx, config.debug_update_check).await;
            tracing::error!("Error in updates::checker_task: {error:#}");
        });

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
            let exe = std::env::current_exe().context("Can't find our own exe path")?;
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

        #[cfg(target_os = "linux")]
        let tray = system_tray::Tray::new(&tokio::runtime::Handle::current(), move |event| {
            handle_system_tray_event(&tray_tx, event);
        });
        #[cfg(not(target_os = "linux"))]
        let tray = {
            tray_icon::menu::MenuEvent::set_event_handler(Some(
                move |event: tray_icon::menu::MenuEvent| {
                    if let Some(event) = system_tray::decode_menu_event(&event.id.0) {
                        handle_system_tray_event(&tray_tx, event);
                    }
                },
            ));

            let gui = gui.clone();
            system_tray::Tray::new(Box::new(move |f| gui.post(move |_| f()))).await?
        };
        let integration = FreyaIntegration { tray, gui };

        let legacy_advanced_settings_path = known_dirs::settings()
            .context("`known_dirs::settings` failed")?
            .join("advanced_settings.json");

        let ctrl_task = tokio::spawn(Controller::start(
            SocketId::Tunnel,
            integration,
            ctlr_rx,
            general_settings,
            developer_settings,
            legacy_advanced_settings_path,
            reloader,
            config.telemetry_allowed,
            updates_rx,
            gui_ipc,
        ));

        anyhow::Ok(ctrl_task)
    });

    // Building the event loop ourselves turns a missing display into an error rather than a panic.
    let event_loop = EventLoop::builder()
        .build()
        .context("Failed to start the GUI event loop")?;
    let launch_config = ui::FONTS
        .iter()
        .fold(LaunchConfig::new(), |launch_config, (family, bytes)| {
            launch_config.with_font(*family, Bytes::from_static(bytes))
        })
        .with_default_font(ui::SANS)
        .with_global_context(ui)
        .with_event_loop(event_loop)
        .with_exit_on_close(false)
        .with_task(move |proxy| async move {
            let _ = ready_tx.send(proxy);
        });

    launch(launch_config);

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
async fn smoke_test(_: mpsc::Sender<ControllerRequest>) -> Result<()> {
    bail!("Smoke test is not built for release binaries.");
}

/// Runs a smoke test and then asks Controller to exit gracefully
///
/// You can purposely fail this test by deleting the exported zip file during
/// the 10-second sleep.
#[cfg(debug_assertions)]
async fn smoke_test(ctrl_tx: mpsc::Sender<ControllerRequest>) -> Result<()> {
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
    ctrl_tx
        .send(ControllerRequest::ExportLogs {
            path: path.clone(),
            stem,
        })
        .await
        .context("Failed to send `ExportLogs` request")?;
    let (tx, rx) = tokio::sync::oneshot::channel();
    ctrl_tx
        .send(ControllerRequest::ClearLogs(tx))
        .await
        .context("Failed to send `ClearLogs` request")?;
    rx.await
        .context("Failed to await `ClearLogs` result")?
        .map_err(|s| anyhow::anyhow!(s))
        .context("`ClearLogs` failed")?;

    // Round-trip a settings save through the Tunnel service so we exercise
    // the protected-storage IPC path. The reply lands in the controller's
    // `AdvancedSettingsApplied` arm; we just need to give it time to land.
    ctrl_tx
        .send(ControllerRequest::ApplyLogFilter(
            AdvancedSettings::default().log_filter,
        ))
        .await
        .context("Failed to send `ApplyLogFilter` request")?;

    // Give the app some time to export the zip and reach steady state
    tokio::time::sleep_until(quit_time).await;

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

    // Check that the protected settings file was written by the Tunnel service.
    anyhow::ensure!(tokio::fs::try_exists(crate::settings::advanced_settings_path()?).await?);

    tracing::info!("Quitting on purpose because of `smoke-test` subcommand");
    ctrl_tx
        .send(ControllerRequest::SystemTrayMenu(system_tray::Event::Quit))
        .await
        .context("Failed to send Quit request")?;

    Ok::<_, anyhow::Error>(())
}

fn handle_system_tray_event(req_tx: &mpsc::Sender<ControllerRequest>, event: system_tray::Event) {
    // `try_send` rather than `blocking_send`: on Linux this runs inside the
    // ksni service's async task, where a blocking send would panic. Tray
    // clicks are human-paced, so the bounded channel won't realistically fill.
    if let Err(e) = req_tx.try_send(ControllerRequest::SystemTrayMenu(event)) {
        tracing::error!("Failed to send tray event: {e}");
    }
}

#[derive(Debug, thiserror::Error)]
#[error("Another instance of Firezone is already running")]
pub struct AlreadyRunning;

#[derive(Debug, thiserror::Error)]
#[error("Failed to communicate with existing Firezone instance")]
pub struct NewInstanceHandshakeFailed(anyhow::Error);

/// Outcome of [`establish_single_instance`].
pub enum SingleInstance {
    /// We acquired the launch lock and now own the GUI IPC pipe
    /// server. The caller proceeds with normal startup; the
    /// `LaunchLock` must outlive the IPC server.
    First {
        server: ipc::Server,
        lock: LaunchLock,
    },
    /// Another instance was already running. We connected to its GUI
    /// IPC pipe, sent `ClientMsg::NewInstance`, awaited the `Ack`,
    /// and closed our end. Production callers bail with
    /// [`AlreadyRunning`] here; the `single-instance` subcommand uses
    /// it as a successful end state for the second-instance side of
    /// the smoke test.
    SecondHandedOff,
}

/// Acquire the launch lock and produce a [`SingleInstance`] describing
/// which role this process plays.
/// First instance: opens the GUI IPC pipe server. Second instance:
/// connects to the running instance, drives the `NewInstance` -> `Ack`
/// handshake to completion, and reports `SecondHandedOff`.
pub async fn establish_single_instance() -> Result<SingleInstance> {
    match launch_lock::acquire()? {
        FirstInstance::Yes(lock) => {
            tracing::debug!("Acquired launch lock, we are the first GUI instance");

            let server =
                ipc::Server::new(SocketId::Gui).context("Failed to create GUI IPC socket")?;
            Ok(SingleInstance::First { server, lock })
        }
        FirstInstance::No => {
            tracing::debug!("Encountered existing launch lock, we are not the first GUI instance");

            // Hand off to the running instance.
            let (read, write) = ipc::connect::<ServerMsg, ClientMsg>(
                SocketId::Gui,
                ipc::ConnectOptions { num_attempts: 3 },
            )
            .await
            .context("Failed to connect to running Firezone instance")
            .map_err(NewInstanceHandshakeFailed)?;

            tokio::time::timeout(Duration::from_secs(5), new_instance_handshake(read, write))
                .await
                .context("Failed to handshake with existing instance in 5s")
                .map_err(NewInstanceHandshakeFailed)?
                .map_err(NewInstanceHandshakeFailed)?;

            Ok(SingleInstance::SecondHandedOff)
        }
    }
}

/// Accept exactly one client on `server`, read its first
/// [`ClientMsg`], send a `ServerMsg::Ack`, and return the message
/// so the caller can log / assert on it.
///
/// Used by the `single-instance` subcommand to exercise the
/// pipe-server side of the launch-lock hand-off without standing up
/// the controller or any other normal-runtime machinery. Production
/// code uses the same `ipc::Server` + framed reader/writer types
/// through `Controller`, but iterating over many clients in an
/// accept loop, not one-shot.
pub async fn accept_one_for_debug(server: &mut ipc::Server) -> Result<ClientMsg> {
    let (mut read, mut write, _pid) = server
        .next_client_split::<ClientMsg, ServerMsg>()
        .await
        .context("Failed to accept GUI IPC client")?;
    let msg = read
        .next()
        .await
        .context("No frame received from second instance")?
        .context("Failed to read frame from second instance")?;
    write
        .send(&ServerMsg::Ack)
        .await
        .context("Failed to ack second instance")?;
    Ok(msg)
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

pub async fn send_and_await_ack(msg: ClientMsg) -> Result<()> {
    let (mut read, mut write) =
        ipc::connect::<ServerMsg, ClientMsg>(SocketId::Gui, ipc::ConnectOptions::default()).await?;

    write.send(&msg).await.context("Failed to send request")?;

    let response = read
        .next()
        .await
        .context("No response received")?
        .context("Failed to receive response")?;

    anyhow::ensure!(response == ServerMsg::Ack);

    tracing::info!("Running instance acknowledged the request, goodbye!");

    Ok(())
}
