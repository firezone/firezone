//! Shared assets loaded into iced at startup.

use iced::Font;
use iced::widget::image::Handle;
use iced::widget::svg;
use std::sync::OnceLock;

/// Firezone logo (PNG, 512x512). Source: `src-frontend/logo.png`.
pub const LOGO_PNG: &[u8] = include_bytes!("../../../src-frontend/logo.png");

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

/// Sidebar / nav-item icons. Minimal monochrome outline SVGs; the
/// stroke uses `currentColor` so the iced `svg` widget's `.color(...)`
/// method tints them at render time to match each item's state.
pub const ICON_HOME: &[u8] = include_bytes!("icons/home.svg");
pub const ICON_COG: &[u8] = include_bytes!("icons/cog.svg");
pub const ICON_WRENCH: &[u8] = include_bytes!("icons/wrench.svg");
pub const ICON_DOC_SEARCH: &[u8] = include_bytes!("icons/doc_search.svg");
pub const ICON_INFO: &[u8] = include_bytes!("icons/info.svg");
pub const ICON_SWATCH: &[u8] = include_bytes!("icons/swatch.svg");

fn svg_handle(bytes: &'static [u8]) -> svg::Handle {
    svg::Handle::from_memory(bytes)
}

pub fn icon_home() -> svg::Handle {
    static HANDLE: OnceLock<svg::Handle> = OnceLock::new();
    HANDLE.get_or_init(|| svg_handle(ICON_HOME)).clone()
}
pub fn icon_cog() -> svg::Handle {
    static HANDLE: OnceLock<svg::Handle> = OnceLock::new();
    HANDLE.get_or_init(|| svg_handle(ICON_COG)).clone()
}
pub fn icon_wrench() -> svg::Handle {
    static HANDLE: OnceLock<svg::Handle> = OnceLock::new();
    HANDLE.get_or_init(|| svg_handle(ICON_WRENCH)).clone()
}
pub fn icon_doc_search() -> svg::Handle {
    static HANDLE: OnceLock<svg::Handle> = OnceLock::new();
    HANDLE.get_or_init(|| svg_handle(ICON_DOC_SEARCH)).clone()
}
pub fn icon_info() -> svg::Handle {
    static HANDLE: OnceLock<svg::Handle> = OnceLock::new();
    HANDLE.get_or_init(|| svg_handle(ICON_INFO)).clone()
}
pub fn icon_swatch() -> svg::Handle {
    static HANDLE: OnceLock<svg::Handle> = OnceLock::new();
    HANDLE.get_or_init(|| svg_handle(ICON_SWATCH)).clone()
}
