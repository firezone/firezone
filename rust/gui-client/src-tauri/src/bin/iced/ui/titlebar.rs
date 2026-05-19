//! Top title bar — shows the name of the current page.

use iced::widget::{container, text};
use iced::{Background, Border, Element, Length, Theme};

use crate::Message;
use crate::state::Route;
use crate::theme;

pub fn view<'a>(route: Route) -> Element<'a, Message> {
    container(
        text(route.title())
            .size(14)
            .color(theme::LIGHT.text_secondary),
    )
    .width(Length::Fill)
    .padding([8, 16])
    .style(|_theme: &Theme| container::Style {
        background: Some(Background::Color(theme::LIGHT.surface)),
        border: Border {
            color: theme::LIGHT.text_muted,
            width: 0.0,
            ..Border::default()
        },
        ..container::Style::default()
    })
    .into()
}
