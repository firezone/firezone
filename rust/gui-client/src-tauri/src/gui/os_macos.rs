//! This file is a stub only to do Tauri UI dev natively on a Mac.
use anyhow::{Result, bail};

use crate::controller::NotificationHandle;

pub async fn set_autostart(_enabled: bool) -> Result<()> {
    bail!("Not implemented")
}

pub(crate) fn show_notification(_title: String, _body: String) -> Result<NotificationHandle> {
    bail!("Not implemented")
}
