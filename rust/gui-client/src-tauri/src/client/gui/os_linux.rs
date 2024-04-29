use super::{ControllerRequest, CtlrTx};
use anyhow::Result;
use secrecy::{ExposeSecret, SecretString};
use tauri::{api::notification::Notification, Manager};

/// Open a URL in the user's default browser
pub(crate) fn open_url(app: &tauri::AppHandle, url: &SecretString) -> Result<()> {
    tauri::api::shell::open(&app.shell_scope(), url.expose_secret(), None)?;
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

/// Show a notification that signals `Controller` when clicked
pub(crate) fn show_clickable_notification(
    _title: &str,
    _body: &str,
    _tx: CtlrTx,
    _req: ControllerRequest,
) -> Result<()> {
    // TODO: Tauri doesn't seem to have clickable notifications on Linux.
    // No indication if it'll be in 2.x or if there's a good third-party replacement
    Ok(())
}
