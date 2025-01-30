use crate::deep_link;
use anyhow::Result;
use firezone_headless_client::ipc;

// TODO: Replace with `anyhow` gradually per <https://github.com/firezone/firezone/pull/3546#discussion_r1477114789>
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Deep-link module error: {0}")]
    DeepLink(#[from] deep_link::Error),
    #[error("IPC service not found")]
    IpcNotFound,
    #[error("IPC closed")]
    IpcClosed,
    #[error("IPC read failed")]
    IpcRead(#[source] anyhow::Error),
    #[error("IPC service terminating")]
    IpcServiceTerminating,
    #[error("WebViewNotInstalled")]
    WebViewNotInstalled,
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl From<ipc::Error> for Error {
    fn from(value: ipc::Error) -> Self {
        match value {
            ipc::Error::NotFound(_) => Self::IpcNotFound,
            ipc::Error::Other(error) => Self::Other(error),
        }
    }
}

impl Error {
    // Decision to put the error strings here: <https://github.com/firezone/firezone/pull/3464#discussion_r1473608415>
    // This message gets shown to users in the GUI and could be localized, unlike
    // messages in the log which only need to be used for `git grep`.
    pub fn user_friendly_msg(&self) -> String {
        match self {
            Error::WebViewNotInstalled => "Firezone cannot start because WebView2 is not installed. Follow the instructions at <https://www.firezone.dev/kb/client-apps/windows-client>.".to_string(),
            Error::DeepLink(deep_link::Error::CantListen) => "Firezone is already running. If it's not responding, force-stop it.".to_string(),
            Error::DeepLink(deep_link::Error::Other(error)) => error.to_string(),
            Error::IpcNotFound => "Couldn't find Firezone IPC service. Is the service running?".to_string(),
            Error::IpcClosed => "IPC connection closed".to_string(),
            Error::IpcRead(_) => "IPC read failure".to_string(),
            Error::IpcServiceTerminating => "The Firezone IPC service is terminating. Please restart the GUI Client.".to_string(),
            Error::Other(error) => error.to_string(),
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
