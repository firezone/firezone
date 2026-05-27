//! Firezone light-mode palette for the xilem GUI, mirroring the iced client's
//! `theme::LIGHT` tokens (themselves mapped from the admin portal's CSS).
//!
//! These feed xilem 0.4's [`Style`](xilem::style::Style) trait
//! (`.color`, `.background_color`, …) and the masonry style properties
//! (`CornerRadius`, `Padding`, `BorderColor`, …) applied via `.prop`.

use xilem::Color;

const fn rgb(r: u8, g: u8, b: u8) -> Color {
    Color::from_rgba8(r, g, b, 0xff)
}

/// App background behind the content area.
pub const CANVAS: Color = rgb(0xee, 0xf1, 0xf6);
/// Sidebar / card surface.
pub const SURFACE: Color = rgb(0xff, 0xff, 0xff);
/// Slightly raised surface (active nav item, secondary buttons).
pub const SURFACE_RAISED: Color = rgb(0xf7, 0xf9, 0xfc);
pub const TEXT_PRIMARY: Color = rgb(0x0f, 0x17, 0x2a);
pub const TEXT_SECONDARY: Color = rgb(0x47, 0x55, 0x69);
pub const TEXT_MUTED: Color = rgb(0xa5, 0xb0, 0xba);
/// Brand orange ("heat wave 500").
pub const BRAND: Color = rgb(0xff, 0x76, 0x05);
/// Darker brand, used for the active nav item's text.
pub const BRAND_HOVER: Color = rgb(0xc2, 0x57, 0x00);
pub const STATUS_WARN: Color = rgb(0xd9, 0x77, 0x06);
/// Text drawn on top of the brand colour (primary buttons).
pub const ON_BRAND: Color = rgb(0xff, 0xff, 0xff);
/// Subtle border for secondary buttons and inputs.
pub const BORDER: Color = rgb(0xcb, 0xd5, 0xe1);
