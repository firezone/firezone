use anyhow::Result;
use tauri::api::notification::Notification;

/// Since clickable notifications don't work on Linux yet, the update text
/// must be different on different platforms
pub(crate) fn show_update_notification(title: &str, download_url: &url::Url) -> Result<()> {
    show_notification(&title, &download_url.to_string())?;
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
