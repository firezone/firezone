//! `fz_button` — Firezone-branded buttons.
//!
//! Variants mirror the Phoenix `<.button variant="primary">` API in the
//! admin portal so the visual language is consistent across the product.

use iced::widget::button::{self, Button, Status};
use iced::{Background, Border, Color, Element, Padding};

use crate::theme::Tokens;

/// Which variant the button should render. Maps 1:1 to the admin
/// portal's button variants.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Variant {
    /// Brand-orange filled button. Use for the single primary action
    /// on a screen.
    Primary,
    /// Subdued button — neutral surface with a light border.
    Secondary,
    /// Text-only button (no fill, no border) for tertiary actions.
    Ghost,
    /// Red filled button for destructive actions.
    Danger,
}

/// Build an `fz-ui` button with the given label and variant, dispatching
/// `on_press` when clicked.
pub fn fz_button<'a, Message: 'a + Clone>(
    label: impl Into<String>,
    variant: Variant,
    on_press: Message,
    tokens: Tokens,
) -> Element<'a, Message> {
    Button::new(iced::widget::text(label.into()))
        .padding(Padding::from([10, 16]))
        .on_press(on_press)
        .style(move |_theme, status| style_for(variant, status, tokens))
        .into()
}

fn style_for(variant: Variant, status: Status, tokens: Tokens) -> button::Style {
    let (background, text, border) = match (variant, status) {
        (Variant::Primary, Status::Hovered) => (tokens.brand_hover, white(), tokens.brand_hover),
        (Variant::Primary, _) => (tokens.brand, white(), tokens.brand),

        (Variant::Secondary, Status::Hovered) => {
            (tokens.surface_raised, tokens.text_primary, tokens.text_muted)
        }
        (Variant::Secondary, _) => (tokens.surface, tokens.text_primary, tokens.text_muted),

        (Variant::Ghost, Status::Hovered) => {
            (tokens.surface_raised, tokens.text_primary, transparent())
        }
        (Variant::Ghost, _) => (transparent(), tokens.text_primary, transparent()),

        (Variant::Danger, Status::Hovered) => (darken(tokens.status_danger), white(), tokens.status_danger),
        (Variant::Danger, _) => (tokens.status_danger, white(), tokens.status_danger),
    };

    button::Style {
        background: Some(Background::Color(background)),
        text_color: text,
        border: Border {
            color: border,
            width: 1.0,
            radius: 6.0.into(),
        },
        ..button::Style::default()
    }
}

const fn white() -> Color {
    Color::WHITE
}

const fn transparent() -> Color {
    Color::TRANSPARENT
}

fn darken(c: Color) -> Color {
    Color {
        r: c.r * 0.85,
        g: c.g * 0.85,
        b: c.b * 0.85,
        a: c.a,
    }
}
