//! This file is a stub only to do Tauri UI dev natively on a Mac.
use anyhow::{Result, bail};

pub async fn set_autostart(_enabled: bool) -> Result<()> {
    bail!("Not implemented")
}

pub(crate) fn show_notification(
    _app: &AppHandle,
    _title: String,
    _body: String,
) -> Result<impl Future<Output = ()>> {
    bail!("Not implemented")
}
