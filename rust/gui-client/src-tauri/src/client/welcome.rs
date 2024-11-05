//! Everything related to the Welcome window

use crate::client::gui::Managed;
use firezone_gui_client_common::controller::ControllerRequest;
use firezone_logging::std_dyn_err;

// Tauri requires a `Result` here, maybe in case the managed state can't be retrieved
#[tauri::command]
pub(crate) async fn sign_in(managed: tauri::State<'_, Managed>) -> anyhow::Result<(), String> {
    if let Err(error) = managed.ctlr_tx.send(ControllerRequest::SignIn).await {
        tracing::error!(
            error = std_dyn_err(&error),
            "Couldn't request `Controller` to begin signing in"
        );
    }
    Ok(())
}
