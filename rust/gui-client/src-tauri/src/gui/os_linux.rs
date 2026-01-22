use anyhow::{Context as _, Result};
use tauri::AppHandle;
use tauri_plugin_notification::NotificationExt as _;

use crate::controller::NotificationHandle;

pub async fn set_autostart(enabled: bool) -> Result<()> {
    let dir = dirs::config_local_dir()
        .context("Can't compute `config_local_dir`")?
        .join("autostart");
    let link = dir.join("firezone-client-gui.desktop");
    if enabled {
        tokio::fs::create_dir_all(&dir)
            .await
            .context("Can't create autostart dir")?;
        let target = std::path::Path::new("/usr/share/applications/firezone-client-gui.desktop");
        // If the link already exists, delete it
        tokio::fs::remove_file(&link).await.ok();
        tokio::fs::symlink(target, link)
            .await
            .context("Can't create autostart link")?;
        tracing::info!("Enabled autostart.");
    } else if tokio::fs::try_exists(&link) // I think this else-if is less intuitive, but Clippy insisted
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
    Ok(())
}

pub(crate) fn show_notification(
    app: &AppHandle,
    title: String,
    body: String,
) -> Result<NotificationHandle> {
    let (_, rx) = futures::channel::oneshot::channel();

    app.notification()
        .builder()
        .title(&title)
        .body(&body)
        .show()?;

    Ok(NotificationHandle { on_click: rx })
}
