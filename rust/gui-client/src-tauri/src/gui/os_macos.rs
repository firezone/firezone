//! This file is a stub only to do Tauri UI dev natively on a Mac.
use anyhow::Result;

pub async fn set_autostart(_enabled: bool) -> Result<()> {
    tracing::warn!("set_autostart is not implemented on macOS; skipping");

    Ok(())
}

pub(crate) fn notification_app_id() -> String {
    crate::BUNDLE_ID.to_owned()
}
