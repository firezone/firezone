// Same Windows subsystem trick as the Tauri binary so release builds don't
// flash a console window.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
// The iced binary is being built up incrementally — a lot of design tokens
// and component variants don't have a caller yet. Re-enable dead_code once
// the Controller wiring lands.
#![allow(dead_code)]

mod state;
mod theme;
mod ui;

use iced::widget::{Space, column, container, row};
use iced::{Element, Fill, Length, Theme};

use state::{AdvancedSettingsState, App, GeneralSettingsState, Route, Session};

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

    // About
    AboutOpenDocs,
}

fn update(app: &mut App, message: Message) {
    match message {
        Message::Navigate(route) => app.route = route,

        Message::SignInPressed => {
            app.session = Session::Loading;
        }
        Message::SignOutPressed => {
            app.session = Session::SignedOut;
        }

        Message::GeneralSettingsAccountSlugChanged(v) => {
            app.general_settings.account_slug = v;
        }
        Message::GeneralSettingsStartMinimizedToggled(v) => {
            app.general_settings.start_minimized = v;
        }
        Message::GeneralSettingsStartOnLoginToggled(v) => {
            app.general_settings.start_on_login = v;
        }
        Message::GeneralSettingsConnectOnStartToggled(v) => {
            app.general_settings.connect_on_start = v;
        }
        Message::GeneralSettingsSave => {
            // Controller wiring will land in a follow-up commit.
        }
        Message::GeneralSettingsReset => {
            app.general_settings = GeneralSettingsState::default();
        }

        Message::AdvancedSettingsAuthUrlChanged(v) => {
            app.advanced_settings.auth_url = v;
        }
        Message::AdvancedSettingsApiUrlChanged(v) => {
            app.advanced_settings.api_url = v;
        }
        Message::AdvancedSettingsLogFilterChanged(v) => {
            app.advanced_settings.log_filter = v;
        }
        Message::AdvancedSettingsSave => {}
        Message::AdvancedSettingsReset => {
            app.advanced_settings = AdvancedSettingsState::default();
        }

        Message::DiagnosticsExportLogs => {}
        Message::DiagnosticsClearLogs => {}

        Message::AboutOpenDocs => {
            let _ = open::that_detached("https://docs.firezone.dev");
        }
    }
}

fn view(app: &App) -> Element<'_, Message> {
    let body: Element<'_, Message> = match app.route {
        Route::Overview => ui::overview::view(app),
        Route::GeneralSettings => ui::general_settings::view(app),
        Route::AdvancedSettings => ui::advanced_settings::view(app),
        Route::Diagnostics => ui::diagnostics::view(app),
        Route::About => ui::about::view(app),
    };

    let main_area = container(body)
        .width(Length::Fill)
        .height(Length::Fill)
        .padding(16)
        .style(|_theme: &Theme| container::Style {
            background: Some(iced::Background::Color(theme::LIGHT.canvas)),
            ..container::Style::default()
        });

    column![
        ui::titlebar::view(app.route),
        row![
            ui::sidebar::view(app.route),
            container(main_area).width(Fill).height(Fill),
        ]
        .height(Fill),
        Space::new().height(0),
    ]
    .into()
}

fn theme(_app: &App) -> Theme {
    theme::light()
}

fn main() -> iced::Result {
    iced::application(App::default, update, view)
        .title("Firezone")
        .theme(theme)
        .window_size((900.0, 500.0))
        .resizable(false)
        .run()
}
