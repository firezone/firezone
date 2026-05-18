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

use iced::widget::{column, container, text};
use iced::{Center, Element, Length};

#[derive(Default)]
struct App;

#[derive(Debug, Clone)]
enum Message {}

fn update(_app: &mut App, _message: Message) {}

fn view(_app: &App) -> Element<'_, Message> {
    container(
        column![
            text("Firezone").size(32),
            text("iced migration in progress").size(14),
        ]
        .spacing(8)
        .align_x(Center),
    )
    .center_x(Length::Fill)
    .center_y(Length::Fill)
    .into()
}

fn main() -> iced::Result {
    iced::application("Firezone", update, view).run()
}
