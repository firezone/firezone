//! Shared assets loaded into iced at startup.

use iced::Font;
use iced::widget::image::Handle;
use std::sync::OnceLock;

/// Firezone logo (PNG, 512x512). Source: `src-frontend/logo.png`.
const LOGO_PNG: &[u8] = include_bytes!("../../../src-frontend/logo.png");

/// Roboto Regular TTF, matching the Elixir admin portal's `font-sans`
/// stack (`Roboto Variable, Roboto, ...`).
pub const ROBOTO_REGULAR: &[u8] = include_bytes!("Roboto-Regular.ttf");

/// Roboto Bold TTF — same family, weight 700.
pub const ROBOTO_BOLD: &[u8] = include_bytes!("Roboto-Bold.ttf");

/// `iced::Font` value referring to the bundled Roboto family. Use as
/// the application's default font via `iced::application(...).default_font(font())`.
pub fn font() -> Font {
    Font::with_name("Roboto")
}

pub fn logo() -> Handle {
    static HANDLE: OnceLock<Handle> = OnceLock::new();
    HANDLE.get_or_init(|| Handle::from_bytes(LOGO_PNG)).clone()
}
