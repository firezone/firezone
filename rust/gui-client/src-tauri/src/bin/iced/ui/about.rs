//! About screen — version info + docs link.

use iced::widget::{Space, column, container, image, text};
use iced::{Center, Element, Length};

use crate::Message;
use crate::assets;
use crate::state::App;
use crate::theme;
use crate::ui::button::{Variant, fz_button};

const APP_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Short git SHA, populated by `vergen` if it ever lands; falls back to
/// "dev" when the binary is built outside a git checkout. Matches the
/// React app's `__GIT_VERSION__?.substring(0, 8)` rendering.
const GIT_SHA: &str = match option_env!("FIREZONE_GIT_SHA") {
    Some(s) => s,
    None => "dev",
};

pub fn view(_app: &App) -> Element<'_, Message> {
    container(
        column![
            image(assets::logo()).width(80).height(80),
            Space::new().height(16),
            text("Version").size(12).color(theme::LIGHT.text_secondary),
            text(APP_VERSION).size(24).color(theme::LIGHT.text_primary),
            text(format!("({})", &GIT_SHA[..GIT_SHA.len().min(8)]))
                .size(11)
                .color(theme::LIGHT.text_muted),
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
