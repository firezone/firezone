//! This file is a stub only to do Tauri UI dev natively on a Mac.
use super::CtlrTx;
use anyhow::{Result, bail};

pub async fn set_autostart(_enabled: bool) -> Result<()> {
    bail!("Not implemented")
}

pub(crate) fn show_notification(_app: &tauri::AppHandle, _title: &str, _body: &str) -> Result<()> {
    bail!("Not implemented")
}

pub(crate) fn show_update_notification(
    _app: &tauri::AppHandle,
    _ctlr_tx: CtlrTx,
    _body: &str,
    _url: url::Url,
) -> Result<()> {
    bail!("Not implemented")
}
