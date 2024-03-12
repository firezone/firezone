use super::{ControllerRequest, CtlrTx, Error};
use anyhow::Result;
use secrecy::{ExposeSecret, SecretString};

/// Open a URL in the user's default browser
pub(crate) fn open_url(_app: &tauri::AppHandle, url: &SecretString) -> Result<()> {
    // This is silly but it might work.
    // Figure out who we were before `sudo`
    let username = std::env::var("SUDO_USER")?;
    std::process::Command::new("sudo")
        // Make sure `XDG_RUNTIME_DIR` is preserved so we can find the Unix domain socket again
        .arg("--preserve-env")
        // Sudo back to our original username
        .arg("--user")
        .arg(username)
        // Use the XDG wrapper for the user's default web browser (this will leak an `xdg-open` process if the user's first browser tab is the Firezone login. That process will end when the browser closes
        .arg("xdg-open")
        .arg(url.expose_secret())
        // Detach, since web browsers, and therefore xdg-open, typically block if there are no windows open and you're opening the first tab from CLI
        .spawn()?;

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
