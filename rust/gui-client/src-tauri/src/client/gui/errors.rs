use super::{deep_link, ipc, logging};
use anyhow::Result;
use firezone_headless_client::FIREZONE_GROUP;

// TODO: Replace with `anyhow` gradually per <https://github.com/firezone/firezone/pull/3546#discussion_r1477114789>
#[allow(dead_code)]
#[derive(Debug, thiserror::Error)]
pub(crate) enum Error {
    #[error("Deep-link module error: {0}")]
    DeepLink(#[from] deep_link::Error),
    #[error("Logging module error: {0}")]
    Logging(#[from] logging::Error),

    // `client.rs` provides a more user-friendly message when showing the error dialog box for certain variants
    #[error("IPC")]
    Ipc(#[from] ipc::Error),
    #[error("UserNotInFirezoneGroup")]
    UserNotInFirezoneGroup,
    #[error("WebViewNotInstalled")]
    WebViewNotInstalled,
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

/// Blocks the thread and shows an error dialog
///
/// Doesn't play well with async, only use this if we're bailing out of the
/// entire process.
pub(crate) fn show_error_dialog(error: &Error) -> Result<()> {
    // Decision to put the error strings here: <https://github.com/firezone/firezone/pull/3464#discussion_r1473608415>
    // This message gets shown to users in the GUI and could be localized, unlike
    // messages in the log which only need to be used for `git grep`.
    let user_friendly_error_msg = match error {
        // TODO: Update this URL
        Error::WebViewNotInstalled => "Firezone cannot start because WebView2 is not installed. Follow the instructions at <https://www.firezone.dev/kb/user-guides/windows-client>.".to_string(),
        Error::DeepLink(deep_link::Error::CantListen) => "Firezone is already running. If it's not responding, force-stop it.".to_string(),
        Error::DeepLink(deep_link::Error::Other(error)) => error.to_string(),
        Error::Ipc(ipc::Error::NotFound(path)) => {
            tracing::error!(?path, "Couldn't find Firezone IPC service");
            "Couldn't find Firezone IPC service. Is the service running?".to_string()
        }
        Error::Ipc(ipc::Error::PermissionDenied) => "Permission denied for Firezone IPC service. This should only happen on dev systems.".to_string(),
        Error::Ipc(ipc::Error::Other(error)) => error.to_string(),
        Error::Logging(_) => "Logging error".to_string(),
        Error::UserNotInFirezoneGroup => format!("You are not a member of the group `{FIREZONE_GROUP}`. Try `sudo usermod -aG {FIREZONE_GROUP} $USER` and then reboot"),
        Error::Other(error) => error.to_string(),
    };
    tracing::error!(?user_friendly_error_msg);

    // I tried the Tauri dialogs and for some reason they don't show our
    // app icon.
    native_dialog::MessageDialog::new()
        .set_title("Firezone Error")
        .set_text(&user_friendly_error_msg)
        .set_type(native_dialog::MessageType::Error)
        .show_alert()?;
    Ok(())
}
