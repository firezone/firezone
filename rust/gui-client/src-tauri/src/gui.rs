//! The Tauri-based GUI Client for Windows and Linux
//!
//! Most of this Client is stubbed out with panics on macOS.
//! The real macOS Client is in `swift/apple`

use crate::{
    controller::{Controller, ControllerRequest, Failure, GuiIntegration, NotificationHandle},
    deep_link,
    ipc::{self, ClientRead, ClientWrite, SocketId},
    logging::FileCount,
    settings::{
        self, AdvancedSettings, AdvancedSettingsLegacy, AdvancedSettingsViewModel, GeneralSettings,
        GeneralSettingsViewModel, MdmSettings,
    },
    updates,
    view::{
        AdvancedSettingsChanged, GeneralSettingsChanged, LogsRecounted, SessionChanged,
        SessionViewModel,
    },
};
use anyhow::{Context, Result, bail};
use fd_lock::{RwLock as FdRwLock, RwLockWriteGuard as FdRwLockWriteGuard};
use futures::SinkExt as _;
use logging::err_with_src;
use std::{
    fs::{File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::PathBuf,
    time::Duration,
};
use tauri::Manager;
use tauri_specta::Event;
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

/// All managed state that we might need to access from odd places like Tauri commands.
///
/// Note that this never gets Dropped because of
/// <https://github.com/tauri-apps/tauri/issues/8631>
#[derive(Clone)]
pub(crate) struct Managed {
    req_tx: mpsc::Sender<ControllerRequest>,
    pub inject_faults: bool,
}

impl Managed {
    pub async fn send_request(&self, msg: ControllerRequest) -> Result<()> {
        let msg_name = msg.to_string();

        self.req_tx
            .send(msg)
            .await
            .with_context(|| format!("Failed to send `{msg_name}`"))
    }

    pub fn blocking_send_request(&self, msg: ControllerRequest) -> Result<()> {
        let msg_name = msg.to_string();

        self.req_tx
            .blocking_send(msg)
            .with_context(|| format!("Failed to send `{msg_name}`"))
    }
}

pub(crate) struct TauriIntegration {
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
    fn notify_session_changed(&self, session: &SessionViewModel) -> Result<()> {
        SessionChanged(session.clone())
            .emit(&self.app)
            .context("Failed to emit `session_changed` event")
    }

    fn notify_settings_changed(
        &self,
        mdm_settings: MdmSettings,
        general_settings: GeneralSettings,
        advanced_settings: AdvancedSettings,
    ) -> Result<()> {
        GeneralSettingsChanged(GeneralSettingsViewModel::new(
            mdm_settings.clone(),
            general_settings,
        ))
        .emit(&self.app)
        .context("Failed to emit `general_settings_changed` event")?;

        AdvancedSettingsChanged(AdvancedSettingsViewModel::new(
            mdm_settings,
            advanced_settings,
        ))
        .emit(&self.app)
        .context("Failed to emit `advanced_settings_changed` event")?;

        Ok(())
    }

    fn notify_logs_recounted(&self, file_count: &FileCount) -> Result<()> {
        LogsRecounted(file_count.clone())
            .emit(&self.app)
            .context("Failed to emit `logs_recounted` event")?;

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

    fn show_notification(
        &self,
        title: impl Into<String>,
        body: impl Into<String>,
    ) -> Result<NotificationHandle> {
        os::show_notification(title.into(), body.into())
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

    fn show_overview_page(&self, session: &SessionViewModel) -> Result<()> {
        // Ensure state in frontend is up-to-date.
        self.notify_session_changed(session)?;
        self.navigate("overview")?;
        self.set_window_visible(true)?;

        Ok(())
    }

    fn show_settings_page(
        &self,
        mdm_settings: MdmSettings,
        general_settings: GeneralSettings,
        advanced_settings: AdvancedSettings,
    ) -> Result<()> {
        self.notify_settings_changed(mdm_settings, general_settings, advanced_settings)?; // Ensure settings are up to date in GUI.
        self.navigate("general-settings")?;
        self.set_window_visible(true)?;

        Ok(())
    }

    fn show_about_page(&self) -> Result<()> {
        self.navigate("about")?;
        self.set_window_visible(true)?;

        Ok(())
    }

    async fn save_general_settings(&self, settings: &GeneralSettings) -> Result<()> {
        settings::save_general(settings).await?;

        Ok(())
    }

    async fn save_advanced_settings(&self, settings: &AdvancedSettings) -> Result<()> {
        settings::save_advanced(settings).await?;

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
    /// When `true`, skip the auth/portal/tunnel stack and drive the tray with
    /// hardcoded fake state. Used by the `debug fake-controller` subcommand
    /// for UI iteration without needing the privileged tunnel service or a
    /// live portal.
    pub fake_controller: bool,
}

/// IPC Messages that a newly launched instance (i.e. a client) may send to an already running instance of Firezone.
///
/// Every connection MUST start with a [`ClientMsg::Hello`] frame whose
/// `cookie` matches the value the first instance wrote to the launch
/// cookie file (see [`LaunchCookie`]). The cookie binds the IPC to a
/// specific *launch generation*: a stale connection from a previous
/// boot, or a connection that failed to read the up-to-date cookie
/// file, is rejected before any payload is processed.
///
/// The cookie is *not* a secret in the same-user threat model — a
/// hostile same-user process can read it directly from the user-
/// private cookie file. The actual identity check is the pipe DACL
/// on Windows (kernel-tracked package SID) and the socket
/// filesystem permissions on Linux. The cookie is the freshness
/// glue between launches.
#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub enum ClientMsg {
    Hello { cookie: [u8; 32] },
    Deeplink(url::Url),
    NewInstance,
}

/// IPC Messages that an already running instance of Firezone may send to a newly launched instance.
#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub enum ServerMsg {
    Ack,
}

/// 32-byte random cookie generated by the first instance on launch and
/// shared with subsequent instances via a user-private file. Wrapped in
/// a newtype so the validation site uses constant-time compare via
/// [`subtle::ConstantTimeEq`] rather than `==`.
#[derive(Clone, Copy)]
pub struct LaunchCookie([u8; 32]);

impl LaunchCookie {
    pub fn new(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    /// Random cookie suitable for production use.
    fn random() -> Self {
        Self(rand::random())
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    /// Constant-time compare. The threat model doesn't actually expose
    /// timing oracles to a network attacker, but using `ConstantTimeEq`
    /// is cheap insurance against future changes.
    pub fn matches(&self, other: &[u8; 32]) -> bool {
        use subtle::ConstantTimeEq as _;
        self.0.ct_eq(other).into()
    }
}

impl std::fmt::Debug for LaunchCookie {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Don't accidentally log the cookie. Both halves of the IPC
        // already trust each other on cookie match; logging it would
        // make crash dumps a credential.
        f.write_str("LaunchCookie(<redacted>)")
    }
}

/// RAII guard holding the advisory file lock on the launch-cookie file
/// for the lifetime of the first instance. Dropped on graceful shutdown
/// (kernel auto-releases the lock on process exit otherwise — including
/// crashes — so a stale cookie file is harmless).
pub struct LaunchLock {
    // The `'static` lifetime is a deliberate leak: this struct lives for
    // the whole process when held. `fd_lock::RwLock` owns the
    // `std::fs::File` and the guard borrows from it; leaking the
    // `RwLock` makes the borrow `'static`.
    _guard: FdRwLockWriteGuard<'static, File>,
}

/// Path of the launch-cookie file. Per-user via the platform-specific
/// `known_dirs::session()` (e.g. `%LOCALAPPDATA%\dev.firezone.client\data`
/// on Windows, `~/.local/share/dev.firezone.client/data` on Linux).
fn launch_cookie_path() -> Result<PathBuf> {
    let dir = known_dirs::session().context("No session directory available")?;
    Ok(dir.join("launch-cookie"))
}

/// Tries to become the first GUI instance.
///
/// On success, returns the lock guard (held for the lifetime of the
/// process) and a freshly generated cookie that has been persisted to
/// the launch-cookie file.
///
/// On failure (a first instance already holds the lock), returns the
/// cookie that the first instance wrote so the caller can present it
/// in the [`ClientMsg::Hello`] frame.
fn try_become_first_instance() -> Result<Result<(LaunchLock, LaunchCookie), LaunchCookie>> {
    let path = launch_cookie_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create `{}`", parent.display()))?;
    }

    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&path)
        .with_context(|| format!("Failed to open launch cookie `{}`", path.display()))?;

    // Leak the `RwLock` so the guard's borrow is `'static`; the
    // first-instance state lives for the whole process either way.
    let lock: &'static mut FdRwLock<File> = Box::leak(Box::new(FdRwLock::new(file)));

    match lock.try_write() {
        Ok(mut guard) => {
            let cookie = LaunchCookie::random();
            guard
                .seek(SeekFrom::Start(0))
                .context("Failed to rewind launch cookie file")?;
            guard
                .set_len(0)
                .context("Failed to truncate launch cookie file")?;
            guard
                .write_all(cookie.as_bytes())
                .context("Failed to write launch cookie")?;
            guard
                .sync_data()
                .context("Failed to fsync launch cookie file")?;
            Ok(Ok((LaunchLock { _guard: guard }, cookie)))
        }
        Err(_) => {
            // Second instance: the process exits very shortly after the
            // hand-off handshake, so the leaked `FdRwLock` (and its
            // underlying file handle) is reclaimed by the OS without
            // user-visible impact. Keeping the `'static` lifetime
            // simple is worth the eight extra bytes.
            let _ = lock; // explicit acknowledgement of the leak
            let mut f = File::open(&path)
                .with_context(|| format!("Failed to read launch cookie `{}`", path.display()))?;
            let mut buf = [0u8; 32];
            f.read_exact(&mut buf).context(
                "Launch cookie file was shorter than 32 bytes; first instance may be \
                 mid-write or the file was truncated externally",
            )?;
            Ok(Err(LaunchCookie::new(buf)))
        }
    }
}

/// Runs the Tauri GUI and returns on exit or unrecoverable error
#[instrument(skip_all)]
pub fn run(
    rt: &Runtime,
    config: RunConfig,
    mdm_settings: MdmSettings,
    advanced_settings: AdvancedSettingsLegacy,
    reloader: logging::FilterReloadHandle,
) -> Result<()> {
    tauri::async_runtime::set(rt.handle().clone());

    let (gui_ipc, gui_cookie, _launch_lock) = rt.block_on(create_gui_ipc_server())?;

    let (general_settings, advanced_settings) =
        rt.block_on(settings::migrate_legacy_settings(advanced_settings));

    let (ctlr_tx, ctlr_rx) = mpsc::channel(5);
    let req_tx = ctlr_tx.clone();
    let (ready_tx, mut ready_rx) = mpsc::channel::<tauri::AppHandle>(1);

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
                if let Err(error) =
                    updates::checker_task(updates_tx, config.debug_update_check).await
                {
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
            let exe =
                tauri_utils::platform::current_exe().context("Can't find our own exe path")?;
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
            crate::BUNDLE_ID,
            app_handle.config().identifier,
            "BUNDLE_ID should match bundle ID in tauri.conf.json"
        );

        let tray = system_tray::Tray::new(app_handle.clone(), |app, event| {
            match handle_system_tray_event(app, event) {
                Ok(_) => {}
                Err(e) => tracing::error!("{e}"),
            }
        })?;
        let integration = TauriIntegration {
            app: app_handle,
            tray,
        };

        let ctrl_task = if config.fake_controller {
            tokio::spawn(crate::fake_controller::run(integration, ctlr_rx))
        } else {
            // Spawn the controller
            tokio::spawn(Controller::start(
                SocketId::Tunnel,
                integration,
                ctlr_tx,
                ctlr_rx,
                general_settings,
                mdm_settings,
                advanced_settings,
                reloader,
                config.telemetry_allowed,
                updates_rx,
                gui_ipc,
                gui_cookie,
            ))
        };

        anyhow::Ok(ctrl_task)
    });

    let tauri_specta_builder = tauri_specta::Builder::<tauri::Wry>::new()
        .events(tauri_specta::collect_events![
            crate::view::SessionChanged,
            crate::view::GeneralSettingsChanged,
            crate::view::AdvancedSettingsChanged,
            crate::view::LogsRecounted,
        ])
        .commands(tauri_specta::collect_commands![
            crate::view::clear_logs,
            crate::view::export_logs,
            crate::view::apply_advanced_settings,
            crate::view::reset_advanced_settings,
            crate::view::apply_general_settings,
            crate::view::reset_general_settings,
            crate::view::sign_in,
            crate::view::sign_out,
            crate::view::update_state,
        ])
        .typ::<crate::view::Error>();

    #[cfg(debug_assertions)]
    {
        let bindings_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../src-frontend/generated/bindings.ts")
            .canonicalize()
            .context("Failed to create absolute path to bindings file")?;

        tracing::debug!(path = %bindings_path.display(), "Exporting TypeScript bindings");

        tauri_specta_builder
            .export(
                specta_typescript::Typescript::default()
                    .bigint(specta_typescript::BigIntExportBehavior::Number)
                    .header("/* eslint-disable */\n/* tslint:disable */\n")
                    .formatter(specta_typescript::formatter::prettier),
                bindings_path,
            )
            .context("Failed to export TypeScript bindings")?;
    }

    tauri::Builder::default()
        .manage(Managed {
            req_tx,
            inject_faults: config.inject_faults,
        })
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
        .invoke_handler(tauri_specta_builder.invoke_handler())
        .setup(move |app| {
            tauri_specta_builder.mount_events(app);

            Ok(())
        })
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_opener::init())
        .build(tauri::generate_context!())
        .context("Failed to build Tauri app instance")?
        .run_return(move |app_handle, event| {
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
    ctrl_tx
        .send(ControllerRequest::SystemTrayMenu(system_tray::Event::Quit))
        .await
        .context("Failed to send Quit request")?;

    Ok::<_, anyhow::Error>(())
}

fn handle_system_tray_event(app: &tauri::AppHandle, event: system_tray::Event) -> Result<()> {
    app.try_state::<Managed>()
        .context("can't get Managed struct from Tauri")?
        .req_tx
        .blocking_send(ControllerRequest::SystemTrayMenu(event))?;
    Ok(())
}

#[derive(Debug, thiserror::Error)]
#[error("Another instance of Firezone is already running")]
pub struct AlreadyRunning;

#[derive(Debug, thiserror::Error)]
#[error("Failed to communicate with existing Firezone instance")]
pub struct NewInstanceHandshakeFailed(anyhow::Error);

/// Create a new instance of the GUI IPC server, or hand off to an
/// already-running instance.
///
/// First, we attempt to acquire an advisory exclusive lock on the
/// launch-cookie file (cross-platform via `fd-lock`: `LockFileEx` on
/// Windows, `flock` on Linux). If we get the lock, we are the first
/// instance: a fresh 32-byte cookie is written to the file, the lock
/// is held for the lifetime of this process, and we return a new IPC
/// server whose accept loop will validate `Hello { cookie }` frames.
///
/// If the lock is already held, another instance is alive. We read
/// its cookie from the file, connect to the GUI IPC socket, send
/// `Hello { cookie }` followed by `NewInstance`, and exit. The lock
/// is released by the kernel on first-instance exit (graceful or
/// otherwise), so a fresh launch after a crash recovers cleanly: the
/// cookie file is overwritten with a new value when the next first
/// instance acquires the lock.
async fn create_gui_ipc_server() -> Result<(ipc::Server, LaunchCookie, LaunchLock)> {
    match try_become_first_instance()? {
        Ok((lock, cookie)) => {
            let server =
                ipc::Server::new(SocketId::Gui).context("Failed to create GUI IPC socket")?;
            Ok((server, cookie, lock))
        }
        Err(cookie) => {
            // Hand off to the running instance and exit.
            let (read, write) = ipc::connect::<ServerMsg, ClientMsg>(
                SocketId::Gui,
                ipc::ConnectOptions { num_attempts: 3 },
            )
            .await
            .context("Failed to connect to running Firezone instance")
            .map_err(NewInstanceHandshakeFailed)?;

            tokio::time::timeout(
                Duration::from_secs(5),
                new_instance_handshake(read, write, cookie),
            )
            .await
            .context("Failed to handshake with existing instance in 5s")
            .map_err(NewInstanceHandshakeFailed)?
            .map_err(NewInstanceHandshakeFailed)?;

            bail!(AlreadyRunning)
        }
    }
}

async fn new_instance_handshake(
    mut read: ClientRead<ServerMsg>,
    mut write: ClientWrite<ClientMsg>,
    cookie: LaunchCookie,
) -> Result<()> {
    write
        .send(&ClientMsg::Hello {
            cookie: *cookie.as_bytes(),
        })
        .await?;
    write.send(&ClientMsg::NewInstance).await?;
    let response = read
        .next()
        .await
        .context("No response received")?
        .context("Failed to receive response")?;

    anyhow::ensure!(response == ServerMsg::Ack);

    Ok(())
}
