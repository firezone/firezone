use anyhow::{Context as _, Result};

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

#[expect(
    clippy::unnecessary_wraps,
    reason = "Signature must match other platforms."
)]
pub(crate) fn show_notification(title: String, body: String) -> Result<NotificationHandle> {
    let (_, rx) = futures::channel::oneshot::channel();

    tokio::spawn(async move {
        let notification = match notify_rust::Notification::new()
            .summary(&title)
            .body(&body)
            .show_async()
            .await
        {
            Ok(n) => n,
            Err(e) => {
                tracing::debug!(%title, "Failed to show notification: {e}");
                return;
            }
        };

        tracing::debug!(%title, %body, "Showing notification");

        notification.on_close(|| {});
    });

    Ok(NotificationHandle { on_click: rx })
}
