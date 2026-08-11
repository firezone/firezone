use anyhow::{Context as _, Result};
use futures::StreamExt as _;
use std::collections::HashMap;

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
pub(crate) fn show_notification(title: String, body: String) -> Result<()> {
    tokio::spawn(async move {
        if let Err(e) = notify(&title, &body).await {
            tracing::debug!(%title, "Failed to show notification: {e:#}");
        }
    });

    Ok(())
}

/// Show a notification about a new release
///
/// Clickable notifications don't work on Linux yet, so the notification only
/// announces the release and the user downloads it via the tray menu.
pub(crate) fn show_update_notification(title: String, _download_url: url::Url) -> Result<()> {
    show_notification(title, String::new())?;

    Ok(())
}

/// Shows a notification via the [`org.freedesktop.Notifications`] D-Bus interface.
///
/// Resolves once the notification is closed: the D-Bus connection must stay
/// open for as long as the notification is showing, otherwise it doesn't get
/// displayed reliably on all desktops.
///
/// [`org.freedesktop.Notifications`]: https://specifications.freedesktop.org/notification-spec/latest/protocol.html
async fn notify(summary: &str, body: &str) -> Result<()> {
    let connection = zbus::Connection::session()
        .await
        .context("Failed to connect to session bus")?;
    let proxy = zbus::Proxy::new(
        &connection,
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
    )
    .await
    .context("Failed to create proxy")?;

    // Subscribe before `Notify` so we cannot miss the close signal.
    let mut closed = proxy
        .receive_signal("NotificationClosed")
        .await
        .context("Failed to subscribe to `NotificationClosed`")?;

    let id: u32 = proxy
        .call(
            "Notify",
            &(
                "Firezone",
                0_u32, // We are not replacing an existing notification.
                "",    // No icon.
                summary,
                body,
                Vec::<&str>::new(),                            // No actions.
                HashMap::<&str, zbus::zvariant::Value>::new(), // No hints.
                -1_i32, // Let the server pick an expiry timeout.
            ),
        )
        .await
        .context("Failed to call `Notify`")?;

    tracing::debug!(%summary, %body, "Showing notification");

    while let Some(message) = closed.next().await {
        let (closed_id, _reason): (u32, u32) = message
            .body()
            .deserialize()
            .context("Failed to deserialize `NotificationClosed`")?;

        if closed_id == id {
            break;
        }
    }

    Ok(())
}
