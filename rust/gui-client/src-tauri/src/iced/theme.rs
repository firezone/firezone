//! Firezone design tokens for iced 0.14, mapped from the Elixir admin
//! portal's CSS custom property layer in `elixir/assets/css/main.css`.
//!
//! Anything that consumes a `iced::theme::Palette` should consume these
//! palettes. Per-widget styling that needs the wider token set
//! (`status-*`, `border-strong`, etc.) should pull from the `Tokens`
//! struct below.

use iced::{Color, Theme, theme::Palette};

/// Brand orange ("heat wave 500"). Used for primary buttons, active
/// states, and the focus ring.
pub const BRAND: Color = Color::from_rgb8(0xff, 0x76, 0x05);

/// Light-mode design tokens.
pub const LIGHT: Tokens = Tokens {
    canvas: Color::from_rgb8(0xee, 0xf1, 0xf6),
    surface: Color::from_rgb8(0xff, 0xff, 0xff),
    surface_raised: Color::from_rgb8(0xf7, 0xf9, 0xfc),
    text_primary: Color::from_rgb8(0x0f, 0x17, 0x2a),
    text_secondary: Color::from_rgb8(0x47, 0x55, 0x69),
    text_tertiary: Color::from_rgb8(0x6e, 0x81, 0x97),
    text_muted: Color::from_rgb8(0xa5, 0xb0, 0xba),
    brand: BRAND,
    brand_hover: Color::from_rgb8(0xc2, 0x57, 0x00),
    status_active: Color::from_rgb8(0x16, 0xa3, 0x4a),
    status_info: Color::from_rgb8(0x25, 0x63, 0xeb),
    status_warn: Color::from_rgb8(0xd9, 0x77, 0x06),
    status_neutral: Color::from_rgb8(0x64, 0x74, 0x8b),
    status_danger: Color::from_rgb8(0xdc, 0x26, 0x26),
};

/// Dark-mode design tokens.
pub const DARK: Tokens = Tokens {
    canvas: Color::from_rgb8(0x08, 0x0c, 0x14),
    surface: Color::from_rgb8(0x0f, 0x16, 0x23),
    surface_raised: Color::from_rgb8(0x17, 0x20, 0x32),
    text_primary: Color::from_rgb8(0xf8, 0xfa, 0xfc),
    text_secondary: Color::from_rgb8(0xa5, 0xb0, 0xba),
    text_tertiary: Color::from_rgb8(0x6e, 0x81, 0x97),
    text_muted: Color::from_rgb8(0x47, 0x55, 0x69),
    brand: BRAND,
    brand_hover: Color::from_rgb8(0xff, 0x9a, 0x47),
    status_active: Color::from_rgb8(0x22, 0xc5, 0x5e),
    status_info: Color::from_rgb8(0x60, 0xa5, 0xfa),
    status_warn: Color::from_rgb8(0xfb, 0xbf, 0x24),
    status_neutral: Color::from_rgb8(0x94, 0xa3, 0xb8),
    status_danger: Color::from_rgb8(0xf8, 0x71, 0x71),
};

/// Granular token set used by per-widget style closures. iced's
/// `Palette` only covers the six headline roles (background, text,
/// primary, success, danger, warning); everything else lives here.
#[derive(Clone, Copy, Debug)]
pub struct Tokens {
    pub canvas: Color,
    pub surface: Color,
    pub surface_raised: Color,
    pub text_primary: Color,
    pub text_secondary: Color,
    pub text_tertiary: Color,
    pub text_muted: Color,
    pub brand: Color,
    pub brand_hover: Color,
    pub status_active: Color,
    pub status_info: Color,
    pub status_warn: Color,
    pub status_neutral: Color,
    pub status_danger: Color,
}

impl Tokens {
    pub fn palette(&self) -> Palette {
        Palette {
            background: self.canvas,
            text: self.text_primary,
            primary: self.brand,
            success: self.status_active,
            danger: self.status_danger,
            warning: self.status_warn,
        }
    }
}

pub fn light() -> Theme {
    Theme::custom("Firezone".to_owned(), LIGHT.palette())
}

pub fn dark() -> Theme {
    Theme::custom("Firezone Dark".to_owned(), DARK.palette())
}
