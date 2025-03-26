use anyhow::Result;

pub const GENERIC_MSG: &str = "An unexpected error occurred. Please try restarting Firezone. If the issue persists, contact your administrator.";

// TODO: Replace with `anyhow` gradually per <https://github.com/firezone/firezone/pull/3546#discussion_r1477114789>
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("IPC closed")]
    IpcClosed,
    #[error("IPC read failed")]
    IpcRead(#[source] anyhow::Error),
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl Error {
    // Decision to put the error strings here: <https://github.com/firezone/firezone/pull/3464#discussion_r1473608415>
    // This message gets shown to users in the GUI and could be localized, unlike
    // messages in the log which only need to be used for `git grep`.
    pub fn user_friendly_msg(&self) -> String {
        match self {
            Error::IpcClosed => "IPC connection closed".to_string(),
            Error::IpcRead(_) => "IPC read failure".to_string(),
            Error::Other(_) => GENERIC_MSG.to_string(),
        }
    }
}

/// Blocks the thread and shows an error dialog
///
/// Doesn't play well with async, only use this if we're bailing out of the
/// entire process.
pub fn show_error_dialog(msg: String) -> Result<()> {
    // I tried the Tauri dialogs and for some reason they don't show our
    // app icon.
    native_dialog::MessageDialog::new()
        .set_title("Firezone Error")
        .set_text(&msg)
        .set_type(native_dialog::MessageType::Error)
        .show_alert()?;
    Ok(())
}
