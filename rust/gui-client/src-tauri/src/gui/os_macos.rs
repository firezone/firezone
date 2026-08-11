//! This file is a stub only to do Tauri UI dev natively on a Mac.
use anyhow::Result;

pub async fn set_autostart(_enabled: bool) -> Result<()> {
    tracing::warn!("set_autostart is not implemented on macOS; skipping");

    Ok(())
}

#[expect(
    clippy::unnecessary_wraps,
    reason = "Signature must match other platforms."
)]
pub(crate) fn show_notification(_title: String, _body: String) -> Result<()> {
    tracing::warn!("show_notification is not implemented on macOS; skipping");

    Ok(())
}

#[expect(
    clippy::unnecessary_wraps,
    reason = "Signature must match other platforms."
)]
pub(crate) fn show_update_notification(_title: String, _download_url: url::Url) -> Result<()> {
    tracing::warn!("show_update_notification is not implemented on macOS; skipping");

    Ok(())
}
