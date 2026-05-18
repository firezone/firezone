//! The Firezone GUI client, iced variant.
//!
//! This binary is being built up in parallel with the existing Tauri-based
//! `firezone-gui-client` and is gated behind the `iced-binary` Cargo feature
//! so that a default `cargo build` of the crate doesn't drag in iced + wgpu
//! deps. Once parity is reached the Tauri binary will be deleted and this
//! one renamed.

// Same Windows subsystem trick as the Tauri binary so release builds don't
// flash a console window.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
// The iced binary is being built up incrementally — most of the token table
// and the Secondary / Ghost / Danger button variants don't have a caller
// yet. Re-enable dead_code once the screens and integration land.
#![allow(dead_code)]

mod theme;
mod ui;

use iced::widget::{column, container, text};
use iced::{Center, Element, Length, Theme};

use ui::button::{Variant, fz_button};

#[derive(Default)]
struct App;

#[derive(Debug, Clone)]
enum Message {
    SignInPressed,
}

fn update(_app: &mut App, _message: Message) {
    // No-op until the Controller wiring lands in a follow-up commit.
}

fn view(_app: &App) -> Element<'_, Message> {
    container(
        column![
            text("Firezone").size(32).color(theme::LIGHT.text_primary),
            text("iced migration in progress")
                .size(14)
                .color(theme::LIGHT.text_secondary),
            fz_button(
                "Sign in",
                Variant::Primary,
                Message::SignInPressed,
                theme::LIGHT
            ),
        ]
        .spacing(16)
        .align_x(Center),
    )
    .center_x(Length::Fill)
    .center_y(Length::Fill)
    .into()
}

fn theme(_app: &App) -> Theme {
    theme::light()
}

fn main() -> iced::Result {
    iced::application(App::default, update, view)
        .title("Firezone")
        .theme(theme)
        .run()
}
