// Same Windows subsystem trick as the Tauri binary so release builds don't
// flash a console window.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
// The iced binary is being built up incrementally — a lot of design tokens
// and component variants don't have a caller yet. Re-enable dead_code once
// the rest of the migration lands.
#![allow(dead_code)]

mod assets;
mod integration;
mod state;
mod theme;
mod tray;
mod ui;

use std::path::PathBuf;
use std::sync::Mutex;

use clap::Parser;
use firezone_gui_client::controller::{Controller, ControllerRequest};
use firezone_gui_client::gui::system_tray;
use firezone_gui_client::ipc::SocketId;
use firezone_gui_client::logging::{self, FileCount, FilterReloadHandle};
use firezone_gui_client::settings::{
    self, AdvancedSettings, GeneralSettings, MdmSettings,
};
use firezone_gui_client::{GeneralSettingsForm, SessionViewModel, deep_link};
use iced::futures::SinkExt as _;
use iced::widget::{container, row};
use iced::window::{self, Mode};
use iced::{Element, Fill, Length, Subscription, Task, Theme};
use tokio::sync::mpsc;

use integration::{IcedIntegration, UiUpdate};
use state::{AdvancedSettingsState, App, GeneralSettingsState, Route, Session};

/// Handed off from `try_main` into the subscription. iced's
/// `Subscription::run(fn_pointer)` requires a stable identity, which means
/// I can't capture the receiver in a closure — stuff it in a static
/// instead and take it on first poll.
static UI_RX_SLOT: Mutex<Option<mpsc::UnboundedReceiver<UiUpdate>>> = Mutex::new(None);

/// Boot-time resources that the iced `boot` closure consumes once.
///
/// iced calls boot via a `Fn` (so it can in principle re-boot), which
/// prevents moving non-`Clone` resources directly through closure
/// captures. We stash everything here and `.take()` it on first call;
/// any subsequent call returns a no-op `App` (iced never does this in
/// practice — boot fires once).
struct BootResources {
    ctrl_tx: mpsc::Sender<ControllerRequest>,
    ctrl_rx: mpsc::Receiver<ControllerRequest>,
    integration: IcedIntegration,
    reloader: FilterReloadHandle,
    general_settings: GeneralSettings,
    mdm_settings: MdmSettings,
    advanced_settings: AdvancedSettings,
}

static BOOT_RESOURCES: Mutex<Option<BootResources>> = Mutex::new(None);

/// Initial window dimensions.
const WINDOW_SIZE: iced::Size = iced::Size {
    width: 900.0,
    height: 500.0,
};

fn window_settings() -> iced::window::Settings {
    iced::window::Settings {
        size: WINDOW_SIZE,
        resizable: false,
        // Required: when iced auto-closes the window (the default),
        // the `CloseRequested` event isn't pushed to the subscription
        // queue, so our `WindowCloseRequested` handler never runs and
        // `app.window_id` stays stale `Some(...)`. The next tray
        // click then thinks the window's still up and tries to raise
        // it instead of opening a new one.
        exit_on_close_request: false,
        ..iced::window::Settings::default()
    }
}

/// Show the main window. If one is already open, raise it; otherwise
/// open a new one and remember its id. We run as an `iced::daemon`,
/// so closing the last window doesn't exit the process — the tray
/// can always reopen.
fn show_window(app: &mut App) -> Task<Message> {
    match app.window_id {
        Some(id) => window::set_mode(id, Mode::Windowed),
        None => {
            let (id, open_task) = window::open(window_settings());
            app.window_id = Some(id);
            open_task.map(|id| Message::WindowOpened(Some(id)))
        }
    }
}

#[derive(Clone)]
pub enum Message {
    Navigate(Route),

    // Overview
    SignInPressed,
    SignOutPressed,

    // General settings
    GeneralSettingsAccountSlugChanged(String),
    GeneralSettingsStartMinimizedToggled(bool),
    GeneralSettingsStartOnLoginToggled(bool),
    GeneralSettingsConnectOnStartToggled(bool),
    GeneralSettingsSave,
    GeneralSettingsReset,

    // Advanced settings
    AdvancedSettingsAuthUrlChanged(String),
    AdvancedSettingsApiUrlChanged(String),
    AdvancedSettingsLogFilterChanged(String),
    AdvancedSettingsSave,
    AdvancedSettingsReset,

    // Diagnostics
    DiagnosticsExportLogs,
    DiagnosticsClearLogs,
    DiagnosticsExportLogsDone(Result<(), String>),

    // About
    AboutOpenDocs,

    // Tray. Clicks come back as `Event` (the existing platform-neutral
    // dispatch type used by the Tauri tray); we forward them as
    // `ControllerRequest::SystemTrayMenu(Event)`, the same single sink
    // the Tauri client uses, so the Controller handles every menu
    // event variant uniformly regardless of which UI is driving.
    TrayEvent(system_tray::Event),
    TrayMenu(system_tray::Menu),
    TrayIcon(system_tray::Icon),

    // Window lifecycle
    WindowCloseRequested(window::Id),
    WindowOpened(Option<window::Id>),

    /// Emitted after the async `initialize` task finishes wiring up
    /// the GUI IPC server, deep-link handler, tray, and Controller.
    /// Currently informational only.
    Initialized,

    /// Fires while a toggle animation is in flight so iced re-renders
    /// each frame; the message itself is a no-op (view samples
    /// `Instant::now()` directly).
    AnimationTick,

    // Inbound state updates from the Controller. One variant per
    // `UiUpdate` shape so each can carry its own owned payload without
    // wrapping in `Arc` and dealing with clone semantics.
    SessionChanged(SessionViewModel),
    SettingsChanged {
        mdm: Box<MdmSettings>,
        general: Box<GeneralSettings>,
        advanced: Box<AdvancedSettings>,
    },
    LogsRecounted(FileCount),
    ControllerSetWindowVisible(bool),
    ControllerShowOverview(SessionViewModel),
    ControllerShowSettings {
        mdm: Box<MdmSettings>,
        general: Box<GeneralSettings>,
        advanced: Box<AdvancedSettings>,
    },
    ControllerShowAbout,
}

fn send_request(app: &App, req: ControllerRequest) {
    if let Some(tx) = &app.ctrl_tx {
        if let Err(e) = tx.try_send(req) {
            tracing::warn!("controller request channel full or closed: {e}");
        }
    } else {
        tracing::warn!("controller not started; dropping request");
    }
}

fn update(app: &mut App, message: Message) -> Task<Message> {
    match message {
        Message::Navigate(route) => {
            app.route = route;
            Task::none()
        }

        // Sign-in flows now go through the Controller, which generates
        // the auth Request (with persistent nonce + state), opens the
        // browser via integration.open_url, and processes the deep-link
        // callback. The iced side just reflects the resulting state
        // changes via the `SessionChanged` message.
        Message::SignInPressed => {
            send_request(app, ControllerRequest::SignIn);
            Task::none()
        }
        Message::SignOutPressed => {
            send_request(app, ControllerRequest::SignOut);
            Task::none()
        }

        Message::GeneralSettingsAccountSlugChanged(v) => {
            app.general_settings.account_slug = v;
            Task::none()
        }
        Message::GeneralSettingsStartMinimizedToggled(v) => {
            app.general_settings.start_minimized = v;
            app.general_settings
                .start_minimized_anim
                .go_mut(v, std::time::Instant::now());
            Task::none()
        }
        Message::GeneralSettingsStartOnLoginToggled(v) => {
            app.general_settings.start_on_login = v;
            app.general_settings
                .start_on_login_anim
                .go_mut(v, std::time::Instant::now());
            Task::none()
        }
        Message::GeneralSettingsConnectOnStartToggled(v) => {
            app.general_settings.connect_on_start = v;
            app.general_settings
                .connect_on_start_anim
                .go_mut(v, std::time::Instant::now());
            Task::none()
        }
        Message::GeneralSettingsSave => {
            let s = &app.general_settings;
            send_request(
                app,
                ControllerRequest::ApplyGeneralSettings(Box::new(GeneralSettingsForm {
                    start_minimized: s.start_minimized,
                    start_on_login: s.start_on_login,
                    connect_on_start: s.connect_on_start,
                    account_slug: s.account_slug.clone(),
                })),
            );
            Task::none()
        }
        Message::GeneralSettingsReset => {
            send_request(app, ControllerRequest::ResetGeneralSettings);
            Task::none()
        }

        Message::AdvancedSettingsAuthUrlChanged(v) => {
            app.advanced_settings.auth_url = v;
            Task::none()
        }
        Message::AdvancedSettingsApiUrlChanged(v) => {
            app.advanced_settings.api_url = v;
            Task::none()
        }
        Message::AdvancedSettingsLogFilterChanged(v) => {
            app.advanced_settings.log_filter = v;
            Task::none()
        }
        Message::AdvancedSettingsSave => {
            if let Some(advanced) = app.advanced_settings.to_settings() {
                send_request(
                    app,
                    ControllerRequest::ApplyAdvancedSettings(Box::new(advanced)),
                );
            } else {
                tracing::warn!("advanced settings save: one of the URLs failed to parse");
            }
            Task::none()
        }
        Message::AdvancedSettingsReset => {
            // No dedicated ControllerRequest for advanced-settings reset;
            // the Tauri client just submits the defaults via
            // ApplyAdvancedSettings.
            send_request(
                app,
                ControllerRequest::ApplyAdvancedSettings(Box::new(AdvancedSettings::default())),
            );
            Task::none()
        }

        Message::DiagnosticsExportLogs => {
            Task::perform(export_logs(), Message::DiagnosticsExportLogsDone)
        }
        Message::DiagnosticsExportLogsDone(Err(e)) => {
            tracing::warn!("failed to export logs: {e}");
            Task::none()
        }
        Message::DiagnosticsExportLogsDone(Ok(())) => Task::none(),
        Message::DiagnosticsClearLogs => {
            if let Some(tx) = &app.ctrl_tx {
                let (cb_tx, _cb_rx) = tokio::sync::oneshot::channel();
                let _ = tx.try_send(ControllerRequest::ClearLogs(cb_tx));
            }
            Task::none()
        }

        Message::AboutOpenDocs => {
            let _ = open::that_detached("https://docs.firezone.dev");
            Task::none()
        }

        Message::WindowCloseRequested(id) => {
            // Daemon mode: closing the only window keeps the app
            // alive. `window::close` actually destroys the surface
            // (cross-platform, including Wayland where
            // `Mode::Hidden` was a no-op); tray clicks reopen via
            // `show_window`.
            app.window_id = None;
            window::close(id)
        }
        Message::WindowOpened(Some(id)) => {
            app.window_id = Some(id);
            Task::none()
        }
        Message::WindowOpened(None) => Task::none(),
        Message::Initialized => Task::none(),
        Message::AnimationTick => Task::none(),

        // The Controller handles every `Event` variant the Tauri tray
        // emits — favorites, clipboard, internet-resource toggle, URL
        // open, sign-in, sign-out, etc. We just forward. `Event::Quit`
        // additionally tells iced to exit so the user actually sees
        // the window close; the Controller still gets the Quit so it
        // can send the Disconnect IPC on the way out.
        Message::TrayEvent(event) => {
            let exit = matches!(event, system_tray::Event::Quit);
            send_request(app, ControllerRequest::SystemTrayMenu(event));
            if exit { iced::exit() } else { Task::none() }
        }
        Message::TrayMenu(menu) => {
            tray::set_menu(menu);
            Task::none()
        }
        Message::TrayIcon(icon) => {
            tray::set_icon(icon);
            Task::none()
        }

        Message::SessionChanged(view) => {
            set_session(app, view);
            Task::none()
        }
        Message::SettingsChanged {
            mdm,
            general,
            advanced,
        } => {
            apply_settings(app, *mdm, *general, *advanced);
            Task::none()
        }
        Message::LogsRecounted(fc) => {
            app.log_count = fc.into();
            Task::none()
        }
        Message::ControllerSetWindowVisible(visible) => {
            if visible {
                show_window(app)
            } else if let Some(id) = app.window_id.take() {
                window::close(id)
            } else {
                Task::none()
            }
        }
        Message::ControllerShowOverview(view) => {
            set_session(app, view);
            app.route = Route::Overview;
            show_window(app)
        }
        Message::ControllerShowSettings {
            mdm,
            general,
            advanced,
        } => {
            apply_settings(app, *mdm, *general, *advanced);
            app.route = Route::GeneralSettings;
            show_window(app)
        }
        Message::ControllerShowAbout => {
            app.route = Route::About;
            show_window(app)
        }
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

fn view(app: &App, _window: window::Id) -> Element<'_, Message> {
    let body: Element<'_, Message> = match app.route {
        Route::Overview => ui::overview::view(app),
        Route::GeneralSettings => ui::general_settings::view(app),
        Route::AdvancedSettings => ui::advanced_settings::view(app),
        Route::Diagnostics => ui::diagnostics::view(app),
        Route::About => ui::about::view(app),
        Route::ColorPalette => ui::color_palette::view(app),
    };

    // Single source of outer breathing room — screens themselves
    // shouldn't add extra padding on top of this.
    let main_area = container(body)
        .width(Length::Fill)
        .height(Length::Fill)
        .padding(20)
        .style(|_theme: &Theme| container::Style {
            background: Some(iced::Background::Color(theme::LIGHT.canvas)),
            ..container::Style::default()
        });

    row![
        ui::sidebar::view(app.route),
        container(main_area).width(Fill).height(Fill),
    ]
    .height(Fill)
    .into()
}

fn theme(_app: &App, _window: window::Id) -> Theme {
    theme::light()
}

fn title(_app: &App, _window: window::Id) -> String {
    "Firezone".to_owned()
}

/// True while any of the General-Settings toggles is mid-animation.
/// Drives the per-frame redraw subscription.
fn any_animating(app: &App) -> bool {
    let now = std::time::Instant::now();
    let g = &app.general_settings;
    g.start_minimized_anim.is_animating(now)
        || g.start_on_login_anim.is_animating(now)
        || g.connect_on_start_anim.is_animating(now)
}

async fn export_logs() -> Result<(), String> {
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

/// Drains the UI-update channel and produces iced Messages. Wrapped in
/// a free function so its identity is stable across renders.
fn ui_update_stream() -> impl iced::futures::Stream<Item = Message> {
    iced::stream::channel(
        16,
        |mut output: iced::futures::channel::mpsc::Sender<Message>| async move {
            let mut rx = match UI_RX_SLOT.lock().unwrap_or_else(|p| p.into_inner()).take() {
                Some(rx) => rx,
                None => return,
            };
            while let Some(update) = rx.recv().await {
                let msg = match update {
                    UiUpdate::SessionChanged(v) => Message::SessionChanged(v),
                    UiUpdate::SettingsChanged {
                        mdm,
                        general,
                        advanced,
                    } => Message::SettingsChanged {
                        mdm: Box::new(mdm),
                        general: Box::new(general),
                        advanced: Box::new(advanced),
                    },
                    UiUpdate::LogsRecounted(fc) => Message::LogsRecounted(fc),
                    UiUpdate::TrayIcon(icon) => Message::TrayIcon(icon),
                    UiUpdate::TrayMenu(app_state) => {
                        // The Controller only ever pushes `AppState`
                        // on state transitions; it doesn't separately
                        // call `set_tray_icon`. Derive the icon from
                        // the state here (matching what the Tauri
                        // `Tray::update` does internally) and emit a
                        // `TrayIcon` message alongside the `TrayMenu`
                        // one so the bar icon tracks Loading /
                        // SignedIn / SignedOut + UpdateReady.
                        let icon = system_tray::icon_from_state(&app_state);
                        if output.send(Message::TrayIcon(icon)).await.is_err() {
                            break;
                        }
                        Message::TrayMenu((*app_state).into_menu())
                    }
                    UiUpdate::SetWindowVisible(v) => Message::ControllerSetWindowVisible(v),
                    UiUpdate::NavigateOverview(v) => Message::ControllerShowOverview(v),
                    UiUpdate::NavigateSettings {
                        mdm,
                        general,
                        advanced,
                    } => Message::ControllerShowSettings {
                        mdm: Box::new(mdm),
                        general: Box::new(general),
                        advanced: Box::new(advanced),
                    },
                    UiUpdate::NavigateAbout => Message::ControllerShowAbout,
                };
                if output.send(msg).await.is_err() {
                    break;
                }
            }
        },
    )
}

/// CLI parser. Mirrors the Tauri client's `open-deep-link` mode so the OS
/// can launch us with `firezone-client-gui-iced open-deep-link <url>`.
#[derive(Parser)]
#[command(version, about = "Firezone GUI client (iced)")]
struct Cli {
    #[command(subcommand)]
    command: Option<Cmd>,
}

#[derive(clap::Subcommand)]
enum Cmd {
    OpenDeepLink { url: String },
}

fn main() -> std::process::ExitCode {
    let cli = Cli::parse();

    // Bootstrap logging early so any failures during setup are visible.
    // Held in an `Option` so we can `.take()` and drop it before the
    // real subscriber is installed in `try_main` — keeping the
    // bootstrap subscriber alive past `setup_gui` leaves the main
    // thread with a different (thread-local) subscriber than tokio
    // workers (global), which makes tracing-subscriber's Registry
    // panic with "tried to drop a ref to Id(N), but no such span
    // exists" the first time a span hops threads.
    let mut bootstrap_log_guard = logging::setup_bootstrap()
        .inspect_err(|e| tracing::warn!("bootstrap log setup failed: {e:#}"))
        .ok();

    // CLI mode: forward a deep-link URL to the running primary
    // instance. iced isn't involved, so build a one-shot tokio runtime
    // for the single async call.
    if let Some(Cmd::OpenDeepLink { url }) = cli.command {
        return match deep_link_cli(url) {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(e) => {
                tracing::error!("failed to forward deep-link: {e:#}");
                std::process::ExitCode::FAILURE
            }
        };
    }

    match try_main(bootstrap_log_guard.take()) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            tracing::error!("iced GUI failed: {e:#}");
            std::process::ExitCode::FAILURE
        }
    }
}

fn deep_link_cli(url: String) -> anyhow::Result<()> {
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(async move {
        let url = url::Url::parse(&url)?;
        deep_link::open(url).await
    })
}

fn try_main(bootstrap_log_guard: Option<tracing::subscriber::DefaultGuard>) -> anyhow::Result<()> {
    // Load settings off disk (synchronous; no runtime needed).
    let mdm_settings = settings::load_mdm_settings()
        .inspect_err(|e| tracing::debug!("Failed to load MDM settings: {e:#}"))
        .unwrap_or_default();
    let general_settings = settings::load_general_settings().unwrap_or_default();
    let advanced_settings = settings::load_advanced_settings().unwrap_or_default();

    // Real logging — replaces the bootstrap logger. The bootstrap
    // guard must be dropped **before** `setup_gui` installs the real
    // global subscriber, otherwise the main thread keeps the bootstrap
    // subscriber as its thread-local default while tokio workers see
    // the global one, and spans that hop threads make
    // tracing-subscriber's Registry panic.
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

    // Synchronous channel creation (mpsc::channel doesn't need a
    // runtime, just allocates).
    let (ctrl_tx, ctrl_rx) = mpsc::channel::<ControllerRequest>(16);
    let (integration, ui_rx) = IcedIntegration::new();
    *UI_RX_SLOT.lock().unwrap_or_else(|p| p.into_inner()) = Some(ui_rx);
    *BOOT_RESOURCES.lock().unwrap_or_else(|p| p.into_inner()) = Some(BootResources {
        ctrl_tx,
        ctrl_rx,
        integration,
        reloader,
        general_settings,
        mdm_settings,
        advanced_settings,
    });

    // Tray statics must be initialised *before* iced takes over the
    // main thread — otherwise:
    //   * On Win/Mac, the `TrayIcon`'s `thread_local` would end up on
    //     a tokio worker (where the deferred init would run) rather
    //     than the main thread, and subsequent `set_menu`/`set_icon`
    //     calls from iced's `update` (on main) wouldn't see it.
    //   * On Linux, iced polls our subscription on its first frame.
    //     If `EVENT_RX` hadn't been allocated yet, the stream would
    //     return immediately and iced would treat the subscription
    //     as completed, dropping every subsequent tray click on the
    //     floor.
    // The ksni service itself is spawned later from `initialize`,
    // where the tokio runtime is available.
    if let Err(e) = tray::install() {
        tracing::warn!("failed to install system tray: {e}");
    }

    // Hand control to iced. iced creates one (and only one) tokio
    // runtime under the hood (`iced_futures::backend::default::Executor =
    // tokio::runtime::Runtime`) and drives every async `Task` /
    // `Subscription` on it. The async init in `boot` — `Server::new`,
    // `deep_link::register`, `tray::install`, `Controller::start` —
    // all run as tokio tasks on that single runtime, so there are no
    // cross-runtime tracing-subscriber races.
    //
    // We use `iced::daemon` rather than `iced::application` so the
    // process doesn't exit when the last window closes. The X button
    // calls `window::close`, which on Linux actually destroys the
    // surface (cross-platform — `Mode::Hidden` only mapped to
    // `set_visible(false)`, which is a no-op on Wayland), and a
    // subsequent tray click opens a fresh window.
    iced::daemon(boot, update, view)
        .title(title)
        .theme(theme)
        .default_font(assets::font())
        .font(assets::ROBOTO_REGULAR)
        .font(assets::ROBOTO_BOLD)
        .subscription(|app| {
            let mut subs = vec![
                tray::subscription(),
                window::close_requests().map(Message::WindowCloseRequested),
                Subscription::run(ui_update_stream),
            ];
            // Only drive per-frame redraws while a toggle is mid-
            // transition; otherwise iced sleeps until the next event.
            if any_animating(app) {
                subs.push(
                    iced::time::every(std::time::Duration::from_millis(16))
                        .map(|_| Message::AnimationTick),
                );
            }
            Subscription::batch(subs)
        })
        .run()?;
    Ok(())
}

fn boot() -> (App, Task<Message>) {
    let Some(res) = BOOT_RESOURCES
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .take()
    else {
        tracing::error!("boot called twice; no resources to consume");
        return (App::default(), Task::none());
    };

    // Ask the Controller to push the current state to us so we don't
    // start with empty forms. The send happens before the Controller
    // is spawned, but the channel buffers 16 messages — by the time
    // the Controller drains its `ctrl_rx`, the `UpdateState` request
    // is sitting at the front.
    let _ = res.ctrl_tx.try_send(ControllerRequest::UpdateState);

    // Daemon mode opens no windows by default — open the main one
    // ourselves and stash the id so `show_window` can raise it.
    let (window_id, open_task) = window::open(window_settings());

    let app = App {
        ctrl_tx: Some(res.ctrl_tx.clone()),
        window_id: Some(window_id),
        ..App::default()
    };

    let init_task = Task::future(async move {
        initialize(res).await;
        Message::Initialized
    });

    let task = Task::batch([
        open_task.map(|id| Message::WindowOpened(Some(id))),
        init_task,
    ]);

    (app, task)
}

/// Runtime-dependent setup: acquire the launch lock, bind the GUI
/// IPC pipe (or hand off to a running instance), register the URI
/// scheme handler, install the tray, and spawn the Controller. Runs
/// from inside iced's `Task::future`, so the ambient tokio runtime
/// is already set.
async fn initialize(res: BootResources) {
    use firezone_gui_client::gui::{SingleInstance, establish_single_instance};

    let (gui_ipc_server, _launch_lock) = match establish_single_instance().await {
        Ok(SingleInstance::First { server, lock }) => (server, lock),
        Ok(SingleInstance::SecondHandedOff) => {
            // The first instance was already running; the handshake
            // told it to surface its own window. We've done our job
            // — bail out cleanly. Bypass iced's teardown because
            // nothing here owns any resources iced cares about.
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

    // On Linux this spawns the ksni service onto the ambient tokio
    // runtime (us). On Win/Mac it's a no-op — the `TrayIcon` was set
    // up synchronously in `install()` and muda's global event
    // receiver doesn't need a service task.
    tray::spawn_service();

    // No in-app updater yet for the iced binary — give the Controller
    // an updates channel that nothing ever sends to.
    let (_updates_tx, updates_rx) =
        mpsc::channel::<Option<firezone_gui_client::updates::Notification>>(16);

    tokio::spawn(async move {
        // `_launch_lock` rides into the spawned task so its lifetime
        // matches the Controller's; dropping it earlier would let a
        // second instance start up.
        let _launch_lock = _launch_lock;
        if let Err(e) = Controller::start(
            SocketId::Tunnel,
            res.integration,
            res.ctrl_tx,
            res.ctrl_rx,
            res.general_settings,
            res.mdm_settings,
            res.advanced_settings,
            res.reloader,
            true, // telemetry_allowed
            updates_rx,
            gui_ipc_server,
        )
        .await
        {
            tracing::error!("Controller exited: {e:#}");
        }
    });
}
