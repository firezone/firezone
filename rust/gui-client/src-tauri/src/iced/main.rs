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
use firezone_gui_client::ipc::{Server, SocketId};
use firezone_gui_client::logging::FileCount;
use firezone_gui_client::settings::{
    self, AdvancedSettings, GeneralSettings, MdmSettings,
};
use firezone_gui_client::{GeneralSettingsForm, SessionViewModel};
use firezone_gui_client::{deep_link, logging};
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

    // Tray
    TrayShowWindow,
    TraySignInClicked,
    TrayAdminPortalClicked,
    TrayQuitClicked,
    OpenExternalUrl(&'static str),

    // Window lifecycle
    WindowCloseRequested(window::Id),
    WindowOpened(Option<window::Id>),

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
        Message::SignInPressed | Message::TraySignInClicked => {
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
            Task::none()
        }
        Message::GeneralSettingsStartOnLoginToggled(v) => {
            app.general_settings.start_on_login = v;
            Task::none()
        }
        Message::GeneralSettingsConnectOnStartToggled(v) => {
            app.general_settings.connect_on_start = v;
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

        Message::TrayShowWindow => match app.window_id {
            Some(id) => window::set_mode(id, Mode::Windowed),
            None => window::oldest().map(Message::WindowOpened),
        },
        Message::TrayAdminPortalClicked => {
            let _ = open::that_detached(&app.advanced_settings.auth_url);
            Task::none()
        }
        Message::OpenExternalUrl(url) => {
            let _ = open::that_detached(url);
            Task::none()
        }
        Message::WindowCloseRequested(id) => {
            app.window_id = Some(id);
            window::set_mode(id, Mode::Hidden)
        }
        Message::WindowOpened(Some(id)) => {
            app.window_id = Some(id);
            window::set_mode(id, Mode::Windowed)
        }
        Message::WindowOpened(None) => Task::none(),
        Message::TrayQuitClicked => iced::exit(),

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
        Message::ControllerSetWindowVisible(visible) => match (app.window_id, visible) {
            (Some(id), true) => window::set_mode(id, Mode::Windowed),
            (Some(id), false) => window::set_mode(id, Mode::Hidden),
            (None, true) => window::oldest().map(Message::WindowOpened),
            (None, false) => Task::none(),
        },
        Message::ControllerShowOverview(view) => {
            set_session(app, view);
            app.route = Route::Overview;
            match app.window_id {
                Some(id) => window::set_mode(id, Mode::Windowed),
                None => window::oldest().map(Message::WindowOpened),
            }
        }
        Message::ControllerShowSettings {
            mdm,
            general,
            advanced,
        } => {
            apply_settings(app, *mdm, *general, *advanced);
            app.route = Route::GeneralSettings;
            match app.window_id {
                Some(id) => window::set_mode(id, Mode::Windowed),
                None => window::oldest().map(Message::WindowOpened),
            }
        }
        Message::ControllerShowAbout => {
            app.route = Route::About;
            match app.window_id {
                Some(id) => window::set_mode(id, Mode::Windowed),
                None => window::oldest().map(Message::WindowOpened),
            }
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

fn view(app: &App) -> Element<'_, Message> {
    let body: Element<'_, Message> = match app.route {
        Route::Overview => ui::overview::view(app),
        Route::GeneralSettings => ui::general_settings::view(app),
        Route::AdvancedSettings => ui::advanced_settings::view(app),
        Route::Diagnostics => ui::diagnostics::view(app),
        Route::About => ui::about::view(app),
        Route::ColorPalette => ui::color_palette::view(app),
    };

    let main_area = container(body)
        .width(Length::Fill)
        .height(Length::Fill)
        .padding(16)
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

fn theme(_app: &App) -> Theme {
    theme::light()
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
                    // The tray menu and icon don't track app state yet.
                    UiUpdate::TrayIcon(_) | UiUpdate::TrayMenu(_) => continue,
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
    let _bootstrap = logging::setup_bootstrap()
        .inspect_err(|e| tracing::warn!("bootstrap log setup failed: {e:#}"))
        .ok();

    let rt = match tokio::runtime::Runtime::new() {
        Ok(rt) => rt,
        Err(e) => {
            tracing::error!("failed to build tokio runtime: {e:#}");
            return std::process::ExitCode::FAILURE;
        }
    };

    // CLI mode: forward a deep-link URL to the running primary instance.
    if let Some(Cmd::OpenDeepLink { url }) = cli.command {
        let result = rt.block_on(async move {
            let url = url::Url::parse(&url)?;
            deep_link::open(url).await
        });
        return match result {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(e) => {
                tracing::error!("failed to forward deep-link: {e:#}");
                std::process::ExitCode::FAILURE
            }
        };
    }

    match try_main(rt) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            tracing::error!("iced GUI failed: {e:#}");
            std::process::ExitCode::FAILURE
        }
    }
}

fn try_main(rt: tokio::runtime::Runtime) -> anyhow::Result<()> {
    // Load settings off disk.
    let mdm_settings = settings::load_mdm_settings()
        .inspect_err(|e| tracing::debug!("Failed to load MDM settings: {e:#}"))
        .unwrap_or_default();
    let general_settings = settings::load_general_settings().unwrap_or_default();
    let advanced_settings = settings::load_advanced_settings().unwrap_or_default();

    // Real logging — replaces the bootstrap logger.
    let log_filter = mdm_settings
        .log_filter
        .as_deref()
        .unwrap_or(&advanced_settings.log_filter)
        .to_owned();
    let logging::Handles {
        logger: _logger,
        reloader,
        cleanup: _cleanup,
    } = logging::setup_gui(&log_filter)?;

    // GUI IPC server — receives forwarded deep-links from secondary
    // launches (`open-deep-link <URL>` mode above) and "I'm a duplicate"
    // pings.
    let gui_ipc_server = Server::new(SocketId::Gui)?;

    // Register the firezone:// URI scheme handler. On Linux this writes
    // a `.desktop` file pointing at our binary; on Windows it sets a
    // registry key; on macOS it's a no-op (handled via Info.plist).
    if let Ok(exe) = std::env::current_exe()
        && let Err(e) = deep_link::register(exe)
    {
        tracing::warn!("failed to register deep-link scheme: {e:#}");
    }

    // Channels: iced → Controller (ControllerRequest), Controller → iced
    // (UiUpdate via IcedIntegration), and an unused updates channel
    // since we don't run the in-app updater for the iced binary yet.
    let (ctrl_tx, ctrl_rx) = mpsc::channel::<ControllerRequest>(16);
    let (_updates_tx, updates_rx) =
        mpsc::channel::<Option<firezone_gui_client::updates::Notification>>(16);
    let (integration, ui_rx) = IcedIntegration::new();
    *UI_RX_SLOT.lock().unwrap_or_else(|p| p.into_inner()) = Some(ui_rx);

    // Spawn the Controller on the tokio runtime we own. iced spins up
    // its own runtime for its `Task`s; the two communicate via the
    // channels above.
    let ctrl_tx_for_controller = ctrl_tx.clone();
    rt.spawn(async move {
        if let Err(e) = Controller::start(
            SocketId::Tunnel,
            integration,
            ctrl_tx_for_controller,
            ctrl_rx,
            general_settings,
            mdm_settings,
            advanced_settings,
            reloader,
            true, // telemetry_allowed
            updates_rx,
            gui_ipc_server,
        )
        .await
        {
            tracing::error!("Controller exited: {e:#}");
        }
    });

    // Run iced (blocks the main thread).
    iced::application(move || boot(ctrl_tx.clone()), update, view)
        .title("Firezone")
        .theme(theme)
        .default_font(assets::font())
        .font(assets::ROBOTO_REGULAR)
        .font(assets::ROBOTO_BOLD)
        .subscription(|_app| {
            Subscription::batch([
                tray::subscription(),
                window::close_requests().map(Message::WindowCloseRequested),
                Subscription::run(ui_update_stream),
            ])
        })
        .exit_on_close_request(false)
        .window_size((900.0, 500.0))
        .resizable(false)
        .run()?;

    drop(rt);
    Ok(())
}

fn boot(ctrl_tx: mpsc::Sender<ControllerRequest>) -> (App, Task<Message>) {
    // Ask the Controller to push the current state to us so we don't
    // start with empty forms.
    let _ = ctrl_tx.try_send(ControllerRequest::UpdateState);
    (
        App {
            ctrl_tx: Some(ctrl_tx),
            ..App::default()
        },
        Task::none(),
    )
}
