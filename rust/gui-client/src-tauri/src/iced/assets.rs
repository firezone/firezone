//! Shared assets loaded into iced at startup.

use iced::widget::image::Handle;
use std::sync::OnceLock;

/// Firezone logo (PNG, 512x512). Source: `src-frontend/logo.png`.
const LOGO_PNG: &[u8] = include_bytes!("../../../src-frontend/logo.png");

pub fn logo() -> Handle {
    static HANDLE: OnceLock<Handle> = OnceLock::new();
    HANDLE.get_or_init(|| Handle::from_bytes(LOGO_PNG)).clone()
}
