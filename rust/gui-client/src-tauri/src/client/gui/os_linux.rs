use anyhow::{Context as _, Result};
use tauri::api::notification::Notification;

pub(crate) async fn set_autostart(enabled: bool) -> Result<()> {
    let dir = dirs::config_local_dir()
        .context("Can't compute `config_local_dir`")?
        .join("autostart");
    let link = dir.join("firezone-client-gui.desktop");
    if enabled {
        tokio::fs::create_dir_all(&dir)
            .await
            .context("Can't create autostart dir")?;
        let target = std::path::Path::new("/usr/share/applications/firezone-client-gui.desktop");
        tokio::fs::symlink(target, link)
            .await
            .context("Can't create autostart link")?;
        tracing::info!("Enabled autostart.");
    } else {
        if tokio::fs::try_exists(&link)
            .await
            .context("Can't check if autostart link exists")?
        {
            tokio::fs::remove_file(&link)
                .await
                .context("Can't remove autostart link")?;
            tracing::info!("Disabled autostart.");
        } else {
            tracing::info!("Autostart is already disabled.");
        }
    }
    Ok(())
}

/// Since clickable notifications don't work on Linux yet, the update text
/// must be different on different platforms
pub(crate) fn show_update_notification(
    _ctlr_tx: super::CtlrTx,
    title: &str,
    download_url: url::Url,
) -> Result<()> {
    show_notification(title, download_url.to_string().as_ref())?;
    Ok(())
}

/// Show a notification in the bottom right of the screen
pub(crate) fn show_notification(title: &str, body: &str) -> Result<()> {
    Notification::new(connlib_shared::BUNDLE_ID)
        .title(title)
        .body(body)
        .show()?;
    Ok(())
}
