//! Entry point + Controller bridge for the experimental xilem GUI, launched
//! via `firezone-gui-client --experimental-xilem-gui`. A direct parallel to
//! `crate::iced::entry`.
//!
//! Like iced, xilem owns the main thread and its own tokio runtime (created by
//! `Xilem::new_simple`). The Controller therefore runs as a task on xilem's
//! runtime — there is no second runtime to nest. The wiring differs from iced
//! only in the transport:
//!
//! * iced uses a `Subscription` to pull `UiUpdate`s; here a single `worker`
//!   view (see `app_logic`) runs the async bridge and feeds updates to the app
//!   through a `MessageProxy`.
//! * UI actions are sent as `ControllerRequest`s through an unbounded channel
//!   the worker hands the app via `store_sender`; the bridge forwards them into
//!   the Controller's bounded request channel.
//!
//! Boot-time resources are stashed in a static and `.take()`n on first poll —
//! the same pattern iced uses — because `worker`'s `init_future` must be
//! non-capturing (zero-sized).

use std::path::PathBuf;
use std::sync::Mutex;

use anyhow::Result;
use tokio::sync::mpsc;
use xilem::core::{MessageProxy, fork};
use xilem::view::{task, worker};
use xilem::{EventLoop, WidgetView, WindowOptions, Xilem};

use crate::SessionViewModel;
use crate::controller::{Controller, ControllerRequest};
use crate::deep_link;
use crate::gui::{SingleInstance, establish_single_instance, system_tray};
use crate::ipc::SocketId;
use crate::logging::{self, FilterReloadHandle};
use crate::settings::{self, AdvancedSettings, GeneralSettings, MdmSettings};
use crate::xilem::integration::{UiUpdate, XilemIntegration};
use crate::xilem::state::{AdvancedSettingsState, App, GeneralSettingsState, Route, Session};
use crate::xilem::{tray, ui};

/// Boot-time resources consumed once by the bridge `worker`'s `init_future`.
/// `worker` requires a non-capturing (zero-sized) init closure, so — exactly
/// like iced's `BOOT_RESOURCES` — we stash everything here and `.take()` it on
/// first poll.
struct BootResources {
    integration: XilemIntegration,
    ui_rx: mpsc::UnboundedReceiver<UiUpdate>,
    reloader: FilterReloadHandle,
    general: GeneralSettings,
    mdm: MdmSettings,
    advanced: AdvancedSettings,
}

static BOOT_RESOURCES: Mutex<Option<BootResources>> = Mutex::new(None);

/// Entry point for the experimental xilem GUI, invoked from
/// `firezone-gui-client --experimental-xilem-gui`. The bootstrap log guard is
/// handed over from the binary's `main` so it can be dropped before the real
/// subscriber is installed (same ordering constraint as the iced path).
pub fn run(bootstrap_log_guard: Option<tracing::subscriber::DefaultGuard>) -> Result<()> {
    // Load settings off disk (synchronous; no runtime needed).
    let mdm_settings = settings::load_mdm_settings()
        .inspect_err(|e| tracing::debug!("Failed to load MDM settings: {e:#}"))
        .unwrap_or_default();
    let general_settings = settings::load_general_settings().unwrap_or_default();
    let advanced_settings = settings::load_advanced_settings().unwrap_or_default();

    // Real logging — replaces the bootstrap logger. Drop the bootstrap guard
    // before installing the global subscriber (see the iced note: mixing the
    // thread-local bootstrap subscriber with the global one panics the
    // Registry when spans hop threads).
    let log_filter = mdm_settings
        .log_filter
        .as_deref()
        .unwrap_or(&advanced_settings.log_filter)
        .to_owned();
    drop(bootstrap_log_guard);
    let logging::Handles {
        logger: _logger,
        reloader,
        cleanup: _cleanup,
    } = logging::setup_gui(&log_filter)?;

    let (integration, ui_rx) = XilemIntegration::new();

    // Seed the initial UI from disk so the forms aren't blank before the
    // Controller's first `UpdateState` push lands.
    let app = App {
        route: Route::Overview,
        session: Session::default(),
        general_settings: GeneralSettingsState::from_settings(&mdm_settings, &general_settings),
        advanced_settings: AdvancedSettingsState::from_settings(&mdm_settings, &advanced_settings),
        general_settings_disk: general_settings.clone(),
        mdm_settings: mdm_settings.clone(),
        log_count: Default::default(),
        ctrl_tx: None,
        export_in_flight: false,
    };

    *BOOT_RESOURCES.lock().unwrap_or_else(|p| p.into_inner()) = Some(BootResources {
        integration,
        ui_rx,
        reloader,
        general: general_settings,
        mdm: mdm_settings,
        advanced: advanced_settings,
    });

    // Install the tray on the main thread before xilem takes it over (the
    // Win/Mac `TrayIcon` is thread-affine). The ksni service / muda forwarder
    // is spawned later, from `bridge_main`, once a tokio runtime exists.
    if let Err(e) = tray::install() {
        tracing::warn!("failed to install system tray: {e}");
    }

    // `new_simple` builds a single, fixed window that exits the process when
    // closed — unlike iced's `daemon` mode (which keeps running in the tray).
    // Daemon-style window lifecycle is one of the missing pieces (see mod.rs).
    let window: WindowOptions<App> = WindowOptions::new("Firezone")
        .with_initial_inner_size(xilem::dpi::LogicalSize::new(900.0, 500.0))
        .with_resizable(false);

    Xilem::new_simple(app, app_logic, window)
        .run_in(EventLoop::with_user_event())
        .map_err(|e| anyhow::anyhow!("xilem event loop failed: {e}"))?;

    Ok(())
}

/// Root view: the visible UI plus the (invisible) bridge `worker` run
/// alongside it via `fork`.
fn app_logic(app: &mut App) -> impl WidgetView<App> + use<> {
    let bridge = worker(
        |proxy: MessageProxy<UiUpdate>, rx: mpsc::UnboundedReceiver<ControllerRequest>| {
            bridge_main(proxy, rx)
        },
        |app: &mut App, tx: mpsc::UnboundedSender<ControllerRequest>| {
            app.ctrl_tx = Some(tx);
        },
        |app: &mut App, update: UiUpdate| apply_update(app, update),
    );

    // One-shot log export: present only while a dialog/zip is in flight, so it
    // fires once when the Diagnostics button flips the flag, then clears it on
    // completion (removing itself on the next render).
    let export = app.export_in_flight.then(|| {
        task(
            |proxy: MessageProxy<()>| async move {
                if let Err(e) = do_export().await {
                    tracing::warn!("failed to export logs: {e}");
                }
                let _ = proxy.message(());
            },
            |app: &mut App, ()| {
                app.export_in_flight = false;
            },
        )
    });

    fork(ui::root(app), (bridge, export))
}

/// Run a native save dialog and export the logs to the chosen path. Mirrors
/// the iced client's `export_logs`.
async fn do_export() -> std::result::Result<(), String> {
    let chosen = tokio::task::spawn_blocking(|| {
        native_dialog::DialogBuilder::file()
            .set_title("Export Firezone logs")
            .set_filename("firezone-logs.zip")
            .save_single_file()
            .show()
    })
    .await
    .map_err(|e| e.to_string())?
    .map_err(|e| e.to_string())?;
    let Some(path) = chosen else {
        return Ok(());
    };
    let stem = path
        .file_stem()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("firezone-logs"));
    logging::export_logs_to(path, stem)
        .await
        .map_err(|e| e.to_string())
}

/// The async bridge: single-instance handshake, deep-link registration, then
/// run the Controller while shuttling requests in and updates out. Runs on
/// xilem's tokio runtime (the `worker` spawns it via `ViewCtx::runtime`).
async fn bridge_main(
    proxy: MessageProxy<UiUpdate>,
    mut rx_from_ui: mpsc::UnboundedReceiver<ControllerRequest>,
) {
    let res = match BOOT_RESOURCES
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .take()
    {
        Some(res) => res,
        None => {
            tracing::error!("xilem bridge started twice; no boot resources");
            return;
        }
    };

    // Bind the GUI IPC pipe, or hand off to an already-running instance.
    let (gui_ipc_server, launch_lock) = match establish_single_instance().await {
        Ok(SingleInstance::First { server, lock }) => (server, lock),
        Ok(SingleInstance::SecondHandedOff) => {
            tracing::info!("another Firezone instance is already running; handed off");
            std::process::exit(0);
        }
        Err(e) => {
            tracing::error!("failed to acquire single-instance lock: {e:#}");
            std::process::exit(1);
        }
    };

    if let Ok(exe) = std::env::current_exe()
        && let Err(e) = deep_link::register(exe)
    {
        tracing::warn!("failed to register deep-link scheme: {e:#}");
    }

    // The Controller wants a *bounded* request channel; the worker hands us an
    // unbounded one fed by the UI. Forward between the two.
    let (ctrl_tx, ctrl_rx) = mpsc::channel::<ControllerRequest>(16);
    let forward_tx = ctrl_tx.clone();
    tokio::spawn(async move {
        while let Some(req) = rx_from_ui.recv().await {
            if forward_tx.send(req).await.is_err() {
                break;
            }
        }
    });

    // Spawn the tray service (Linux: ksni; Win/Mac: muda event forwarder) and
    // drain its clicks into the Controller as `SystemTrayMenu` requests — the
    // same sink the Tauri and iced clients use.
    tray::spawn_service();
    if let Some(mut tray_rx) = tray::take_event_rx() {
        let tray_tx = ctrl_tx.clone();
        tokio::spawn(async move {
            while let Some(event) = tray_rx.recv().await {
                let is_quit = matches!(event, system_tray::Event::Quit);
                let _ = tray_tx.send(ControllerRequest::SystemTrayMenu(event)).await;
                if is_quit {
                    // `new_simple` can't close its window from here, so quit the
                    // process. Give the Controller a moment to send the
                    // Disconnect IPC first. (A graceful, window-aware quit is
                    // part of the window-lifecycle gap — see mod.rs.)
                    tokio::time::sleep(std::time::Duration::from_millis(250)).await;
                    std::process::exit(0);
                }
            }
        });
    }

    // Forward Controller → UI updates to the app via the MessageProxy.
    let mut ui_rx = res.ui_rx;
    tokio::spawn(async move {
        while let Some(update) = ui_rx.recv().await {
            if proxy.message(update).is_err() {
                break;
            }
        }
    });

    // Ask the Controller to push its current state so the UI reflects reality.
    let _ = ctrl_tx.send(ControllerRequest::UpdateState).await;

    // No in-app updater yet — a channel nothing ever sends to.
    let (_updates_tx, updates_rx) = mpsc::channel(16);

    // Hold the launch lock for the Controller's lifetime.
    let _launch_lock = launch_lock;
    if let Err(e) = Controller::start(
        SocketId::Tunnel,
        res.integration,
        ctrl_tx,
        ctrl_rx,
        res.general,
        res.mdm,
        res.advanced,
        res.reloader,
        true, // telemetry_allowed
        updates_rx,
        gui_ipc_server,
    )
    .await
    {
        tracing::error!("Controller exited: {e:#}");
    }
}

/// Apply a Controller → UI update to the app state. Mirrors the `UiUpdate`
/// arms of iced's `update`.
fn apply_update(app: &mut App, update: UiUpdate) {
    match update {
        UiUpdate::SessionChanged(view) => set_session(app, view),
        UiUpdate::SettingsChanged {
            mdm,
            general,
            advanced,
        } => apply_settings(app, mdm, general, advanced),
        UiUpdate::LogsRecounted(fc) => app.log_count = fc.into(),
        UiUpdate::TrayIcon(icon) => tray::set_icon(icon),
        UiUpdate::TrayMenu(app_state) => {
            let app_state = *app_state;
            tray::set_icon(system_tray::icon_from_state(&app_state));
            tray::set_menu(app_state.into_menu());
        }
        // Single always-open window under `new_simple`; nothing to show/hide.
        // (Raising the window from the tray is part of the window gap.)
        UiUpdate::SetWindowVisible(_) => {}
        UiUpdate::NavigateOverview(view) => {
            set_session(app, view);
            app.route = Route::Overview;
        }
        UiUpdate::NavigateSettings {
            mdm,
            general,
            advanced,
        } => {
            apply_settings(app, mdm, general, advanced);
            app.route = Route::GeneralSettings;
        }
        UiUpdate::NavigateAbout => app.route = Route::About,
    }
}

fn set_session(app: &mut App, view: SessionViewModel) {
    app.session = match view {
        SessionViewModel::SignedIn {
            account_slug,
            actor_name,
        } => Session::SignedIn {
            account_slug,
            actor_name,
        },
        SessionViewModel::Loading => Session::Loading,
        SessionViewModel::SignedOut => Session::SignedOut,
    };
}

fn apply_settings(
    app: &mut App,
    mdm: MdmSettings,
    general: GeneralSettings,
    advanced: AdvancedSettings,
) {
    app.mdm_settings = mdm;
    app.general_settings_disk = general.clone();
    app.general_settings = GeneralSettingsState::from_settings(&app.mdm_settings, &general);
    app.advanced_settings = AdvancedSettingsState::from_settings(&app.mdm_settings, &advanced);
}
