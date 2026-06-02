//! This file is a stub only to do Tauri UI dev natively on a Mac.
use anyhow::Result;

use crate::controller::NotificationHandle;

pub async fn set_autostart(_enabled: bool) -> Result<()> {
    tracing::warn!("set_autostart is not implemented on macOS; skipping");

    Ok(())
}

pub(crate) fn show_notification(_title: String, _body: String) -> Result<NotificationHandle> {
    tracing::warn!("show_notification is not implemented on macOS; skipping");

    let (_tx, on_click) = futures::channel::oneshot::channel();

    Ok(NotificationHandle { on_click })
}
