//! Color palette debug page. Mirrors `ColorPalettePage.tsx` so the design
//! token table from `theme.rs` can be eyeballed against the React app.

use iced::widget::{Space, column, container, row, scrollable, text};
use iced::{Background, Border, Color, Element, Length, Theme};

use crate::Message;
use crate::state::App;
use crate::theme::{self, Tokens};

pub fn view(_app: &App) -> Element<'_, Message> {
    scrollable(
        column![
            section("Light tokens", &theme::LIGHT),
            Space::new().height(24),
            section("Dark tokens", &theme::DARK),
        ]
        .padding(16)
        .spacing(12),
    )
    .height(Length::Fill)
    .into()
}

fn section<'a>(title: &'a str, tokens: &Tokens) -> Element<'a, Message> {
    column![
        text(title).size(18).color(theme::LIGHT.text_primary),
        Space::new().height(8),
        swatch_row(
            "Surfaces",
            vec![
                ("canvas", tokens.canvas),
                ("surface", tokens.surface),
                ("surface_raised", tokens.surface_raised),
            ],
        ),
        swatch_row(
            "Text",
            vec![
                ("primary", tokens.text_primary),
                ("secondary", tokens.text_secondary),
                ("tertiary", tokens.text_tertiary),
                ("muted", tokens.text_muted),
            ],
        ),
        swatch_row(
            "Brand",
            vec![("brand", tokens.brand), ("brand_hover", tokens.brand_hover),],
        ),
        swatch_row(
            "Status",
            vec![
                ("active", tokens.status_active),
                ("info", tokens.status_info),
                ("warn", tokens.status_warn),
                ("neutral", tokens.status_neutral),
                ("danger", tokens.status_danger),
            ],
        ),
    ]
    .spacing(6)
    .into()
}

fn swatch_row<'a>(
    label: &'static str,
    swatches: Vec<(&'static str, Color)>,
) -> Element<'a, Message> {
    let mut r = row![
        text(label)
            .size(12)
            .color(theme::LIGHT.text_secondary)
            .width(Length::Fixed(80.0)),
    ]
    .spacing(8);
    for (name, color) in swatches {
        r = r.push(swatch(name, color));
    }
    r.into()
}

fn swatch<'a>(name: &'static str, color: Color) -> Element<'a, Message> {
    column![
        container(Space::new().width(Length::Fill).height(Length::Fixed(40.0)))
            .width(Length::Fixed(96.0))
            .style(move |_theme: &Theme| container::Style {
                background: Some(Background::Color(color)),
                border: Border {
                    color: theme::LIGHT.text_muted,
                    width: 1.0,
                    radius: 4.0.into(),
                },
                ..container::Style::default()
            }),
        text(name)
            .size(10)
            .color(theme::LIGHT.text_tertiary)
            .width(Length::Fixed(96.0)),
    ]
    .spacing(2)
    .into()
}
