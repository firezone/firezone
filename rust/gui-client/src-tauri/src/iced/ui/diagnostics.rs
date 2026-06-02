//! Diagnostics screen — log size + clear/export controls.

use iced::widget::{Space, column, container, row, text};
use iced::{Center, Element, Length};

use crate::iced::Message;
use crate::iced::state::App;
use crate::iced::theme;
use crate::iced::ui::button::{Variant, fz_button};

pub fn view(app: &App) -> Element<'_, Message> {
    let count = &app.log_count;
    let megabytes = (count.bytes as f64) / 1_000_000.0;
    let summary = format!("{} files, {:.1} MB", count.files, megabytes);

    container(
        column![
            Space::new().height(32),
            row![
                text("Log directory size:")
                    .size(14)
                    .color(theme::LIGHT.text_secondary),
                Space::new().width(4),
                text(summary).size(14).color(theme::LIGHT.text_primary),
            ]
            .align_y(Center),
            Space::new().height(32),
            row![
                fz_button(
                    "Export Logs",
                    Variant::Secondary,
                    Message::DiagnosticsExportLogs,
                    theme::LIGHT,
                ),
                fz_button(
                    "Clear Logs",
                    Variant::Secondary,
                    Message::DiagnosticsClearLogs,
                    theme::LIGHT,
                ),
            ]
            .spacing(16),
        ]
        .align_x(Center)
        .spacing(8),
    )
    .center_x(Length::Fill)
    .into()
}
