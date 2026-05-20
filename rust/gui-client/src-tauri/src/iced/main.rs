// Same Windows subsystem trick as the Tauri binary so release builds don't
// flash a console window.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
// The iced binary is being built up incrementally — a lot of design tokens
// and component variants don't have a caller yet. Re-enable dead_code once
// the rest of the migration lands.
#![allow(dead_code)]

mod assets;
mod state;
mod theme;
mod tray;
mod ui;

use std::path::PathBuf;

use firezone_gui_client::logging;
use firezone_gui_client::settings::{
    self, AdvancedSettings, GeneralSettings,
};
use iced::widget::{container, row};
use iced::{Element, Fill, Length, Task, Theme};

use state::{AdvancedSettingsState, App, GeneralSettingsState, LogCount, Route, Session};

#[derive(Debug, Clone)]
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
    GeneralSettingsSaved(Result<(), String>),
    GeneralSettingsReset,

    // Advanced settings
    AdvancedSettingsAuthUrlChanged(String),
    AdvancedSettingsApiUrlChanged(String),
    AdvancedSettingsLogFilterChanged(String),
    AdvancedSettingsSave,
    AdvancedSettingsSaved(Result<(), String>),
    AdvancedSettingsReset,

    // Diagnostics
    DiagnosticsExportLogs,
    DiagnosticsExportLogsDone(Result<(), String>),
    DiagnosticsClearLogs,
    DiagnosticsClearLogsDone(Result<(), String>),
    DiagnosticsLogCountRecounted(LogCount),

    // About
    AboutOpenDocs,

    // Tray
    TrayShowWindow,
    TraySignInClicked,
    TrayAdminPortalClicked,
    TrayQuitClicked,
    OpenExternalUrl(&'static str),
}

fn legacy_to_modern(legacy: &AdvancedSettingsLegacy) -> AdvancedSettings {
    AdvancedSettings {
        auth_url: legacy.auth_base_url.clone(),
        api_url: legacy.api_url.clone(),
        log_filter: legacy.log_filter.clone(),
    }
}

fn update(app: &mut App, message: Message) -> Task<Message> {
    match message {
        Message::Navigate(route) => {
            app.route = route;
            Task::none()
        }

        Message::SignInPressed => {
            // Build the same URL the Tauri client does:
            // `<auth_base_url>/<account_slug>?as=gui-client&nonce=<32-byte hex>&state=<32-byte hex>`
            // The nonce + state are CSRF tokens that the auth server
            // includes in its deep-link callback. We currently don't
            // have a Controller running to receive that callback in
            // the iced binary, so the values are thrown away — they
            // just need to be present and well-formed so the auth
            // server doesn't reject the request.
            let auth_url = sign_in_url(
                &app.advanced_settings.auth_url,
                &app.general_settings.account_slug,
            );
            let _ = open::that_detached(auth_url);
            app.session = Session::Loading;
            Task::none()
        }
        Message::SignOutPressed => {
            app.session = Session::SignedOut;
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
            let next = app.general_settings.to_settings(&app.general_settings_disk);
            app.general_settings_disk = next.clone();
            Task::perform(
                async move {
                    settings::save_general(&next)
                        .await
                        .map_err(|e| e.to_string())
                },
                Message::GeneralSettingsSaved,
            )
        }
        Message::GeneralSettingsSaved(Err(e)) => {
            tracing::warn!("failed to save general settings: {e}");
            Task::none()
        }
        Message::GeneralSettingsSaved(Ok(())) => Task::none(),
        Message::GeneralSettingsReset => {
            app.general_settings =
                GeneralSettingsState::from_settings(&app.mdm_settings, &GeneralSettings::default());
            app.general_settings_disk = GeneralSettings::default();
            let next = app.general_settings_disk.clone();
            Task::perform(
                async move {
                    settings::save_general(&next)
                        .await
                        .map_err(|e| e.to_string())
                },
                Message::GeneralSettingsSaved,
            )
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
        Message::AdvancedSettingsSave => match app.advanced_settings.to_settings() {
            Some(next) => Task::perform(
                async move {
                    settings::save_advanced(&next)
                        .await
                        .map_err(|e| e.to_string())
                },
                Message::AdvancedSettingsSaved,
            ),
            None => {
                tracing::warn!("advanced settings save: one of the URLs failed to parse");
                Task::none()
            }
        },
        Message::AdvancedSettingsSaved(Err(e)) => {
            tracing::warn!("failed to save advanced settings: {e}");
            Task::none()
        }
        Message::AdvancedSettingsSaved(Ok(())) => Task::none(),
        Message::AdvancedSettingsReset => {
            let advanced = legacy_to_modern(&AdvancedSettingsLegacy::default());
            app.advanced_settings =
                AdvancedSettingsState::from_settings(&app.mdm_settings, &advanced);
            Task::perform(
                async move {
                    settings::save_advanced(&advanced)
                        .await
                        .map_err(|e| e.to_string())
                },
                Message::AdvancedSettingsSaved,
            )
        }

        Message::DiagnosticsExportLogs => {
            Task::perform(export_logs(), Message::DiagnosticsExportLogsDone)
        }
        Message::DiagnosticsExportLogsDone(Err(e)) => {
            tracing::warn!("failed to export logs: {e}");
            Task::none()
        }
        Message::DiagnosticsExportLogsDone(Ok(())) => Task::none(),
        Message::DiagnosticsClearLogs => Task::perform(
            async {
                let gui = logging::clear_gui_logs().await.map_err(|e| e.to_string());
                let svc = logging::clear_service_logs()
                    .await
                    .map_err(|e| e.to_string());
                gui.and(svc)
            },
            Message::DiagnosticsClearLogsDone,
        ),
        Message::DiagnosticsClearLogsDone(result) => {
            if let Err(e) = result {
                tracing::warn!("failed to clear logs: {e}");
            }
            Task::perform(recount_logs(), Message::DiagnosticsLogCountRecounted)
        }
        Message::DiagnosticsLogCountRecounted(count) => {
            app.log_count = count;
            Task::none()
        }

        Message::AboutOpenDocs => {
            let _ = open::that_detached("https://docs.firezone.dev");
            Task::none()
        }

        Message::TrayShowWindow => {
            // TODO: iced 0.14's window-management API takes a `window::Id`
            // we don't currently track. The main window is already visible
            // when the app boots, so this is a no-op until we add an
            // explicit window registry.
            Task::none()
        }
        Message::TraySignInClicked => update(app, Message::SignInPressed),
        Message::TrayAdminPortalClicked => {
            let _ = open::that_detached(&app.advanced_settings.auth_url);
            Task::none()
        }
        Message::OpenExternalUrl(url) => {
            let _ = open::that_detached(url);
            Task::none()
        }
        Message::TrayQuitClicked => iced::exit(),
    }
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

/// Load settings from disk synchronously, surface any failure as a warning
/// but keep going with defaults so the UI still boots.
fn boot() -> (App, Task<Message>) {
    let mdm_settings = settings::load_mdm_settings()
        .inspect_err(|e| tracing::debug!("Failed to load MDM settings: {e:#}"))
        .unwrap_or_default();
    let general_disk = settings::load_general_settings().unwrap_or_default();
    let advanced_legacy =
        settings::load_advanced_settings::<AdvancedSettingsLegacy>().unwrap_or_default();
    let advanced = legacy_to_modern(&advanced_legacy);

    let app = App {
        general_settings: GeneralSettingsState::from_settings(&mdm_settings, &general_disk),
        advanced_settings: AdvancedSettingsState::from_settings(&mdm_settings, &advanced),
        general_settings_disk: general_disk,
        mdm_settings,
        ..App::default()
    };

    (
        app,
        Task::perform(recount_logs(), Message::DiagnosticsLogCountRecounted),
    )
}

async fn recount_logs() -> LogCount {
    logging::count_logs()
        .await
        .map(LogCount::from)
        .unwrap_or_default()
}

/// Build the sign-in URL that the auth server expects. Mirrors
/// `Request::to_url` in `gui-client/src-tauri/src/auth.rs`.
fn sign_in_url(auth_base_url: &str, account_slug: &str) -> String {
    let base = match url::Url::parse(auth_base_url) {
        Ok(mut u) => {
            if !account_slug.is_empty() {
                u.set_path(account_slug);
            }
            u.to_string()
        }
        Err(_) => format!(
            "{}{}{}",
            auth_base_url.trim_end_matches('/'),
            if account_slug.is_empty() { "" } else { "/" },
            account_slug
        ),
    };

    let mut nonce_buf = [0u8; 32];
    let mut state_buf = [0u8; 32];
    rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut nonce_buf);
    rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut state_buf);
    let nonce = hex::encode(nonce_buf);
    let state = hex::encode(state_buf);
    format!("{base}?as=gui-client&nonce={nonce}&state={state}")
}

/// Pop a native save-file dialog (off the iced runtime, since
/// `native-dialog` is blocking), then hand the chosen path to
/// `logging::export_logs_to`.
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

fn main() -> iced::Result {
    if let Err(e) = tray::install() {
        // Tray is best-effort. On Linux it lives or dies by whether
        // the user's desktop environment exposes SNI (GNOME needs the
        // AppIndicator extension); on Windows/macOS the OS always has
        // a tray.
        tracing::warn!("failed to install system tray: {e}");
    }

    iced::application(boot, update, view)
        .title("Firezone")
        .theme(theme)
        .default_font(assets::font())
        .font(assets::ROBOTO_REGULAR)
        .font(assets::ROBOTO_BOLD)
        .subscription(|_app| tray::subscription())
        .window_size((900.0, 500.0))
        .resizable(false)
        .run()
}
