//! Left navigation sidebar.

use iced::widget::{button, column, container, text};
use iced::{Background, Border, Element, Length, Padding, Theme};

use crate::Message;
use crate::state::Route;
use crate::theme;

pub fn view<'a>(current: Route) -> Element<'a, Message> {
    let mut items = column![
        nav_item("Overview", Route::Overview, current),
        nav_item("General settings", Route::GeneralSettings, current),
        nav_item("Advanced settings", Route::AdvancedSettings, current),
        nav_item("Diagnostics", Route::Diagnostics, current),
        nav_item("About", Route::About, current),
    ]
    .spacing(2)
    .padding(Padding::from([16, 12]));
    if cfg!(debug_assertions) {
        items = items.push(nav_item("Color palette", Route::ColorPalette, current));
    }
    container(items)
        .width(Length::Fixed(200.0))
        .height(Length::Fill)
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

fn nav_item<'a>(label: &'a str, route: Route, current: Route) -> Element<'a, Message> {
    let active = route == current;
    button(text(label).size(14))
        .width(Length::Fill)
        .padding(Padding::from([8, 12]))
        .on_press(Message::Navigate(route))
        .style(move |_theme: &Theme, status| {
            use iced::widget::button::Status;
            let hovered = matches!(status, Status::Hovered);
            let (bg, fg) = if active {
                (theme::LIGHT.surface_raised, theme::LIGHT.brand_hover)
            } else if hovered {
                (theme::LIGHT.surface_raised, theme::LIGHT.text_primary)
            } else {
                (iced::Color::TRANSPARENT, theme::LIGHT.text_secondary)
            };
            button::Style {
                background: Some(Background::Color(bg)),
                text_color: fg,
                border: Border {
                    color: iced::Color::TRANSPARENT,
                    width: 0.0,
                    radius: 6.0.into(),
                },
                ..button::Style::default()
            }
        })
        .into()
}
