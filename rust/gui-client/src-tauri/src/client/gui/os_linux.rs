use super::{ControllerRequest, CtlrTx, Error};
use anyhow::Result;
use secrecy::{ExposeSecret, SecretString};
use tauri::Manager;

/// Open a URL in the user's default browser
pub(crate) fn open_url(app: &tauri::AppHandle, url: &SecretString) -> Result<()> {
    tauri::api::shell::open(&app.shell_scope(), url.expose_secret(), None)?;
    Ok(())
}

/// Show a notification in the bottom right of the screen
pub(crate) fn show_notification(_title: &str, _body: &str) -> Result<(), Error> {
    // TODO
    Ok(())
}

/// Show a notification that signals `Controller` when clicked
pub(crate) fn show_clickable_notification(
    _title: &str,
    _body: &str,
    _tx: CtlrTx,
    _req: ControllerRequest,
) -> Result<(), Error> {
    // TODO
    Ok(())
}
