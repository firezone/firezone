//! About screen — version info + docs link.

use iced::widget::{Space, column, container, text};
use iced::{Center, Element, Length};

use crate::Message;
use crate::state::App;
use crate::theme;
use crate::ui::button::{Variant, fz_button};

const APP_VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn view(_app: &App) -> Element<'_, Message> {
    container(
        column![
            text("Firezone").size(32).color(theme::LIGHT.text_primary),
            Space::new().height(16),
            text("Version").size(12).color(theme::LIGHT.text_secondary),
            text(APP_VERSION).size(20).color(theme::LIGHT.text_primary),
            Space::new().height(24),
            fz_button(
                "Documentation",
                Variant::Ghost,
                Message::AboutOpenDocs,
                theme::LIGHT,
            ),
        ]
        .align_x(Center)
        .spacing(4),
    )
    .center_x(Length::Fill)
    .center_y(Length::Fill)
    .into()
}
