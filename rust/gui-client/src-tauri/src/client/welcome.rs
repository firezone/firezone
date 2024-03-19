//! Everything related to the Welcome window

use crate::client::gui::{ControllerRequest, Managed};

// Tauri requires a `Result` here, maybe in case the managed state can't be retrieved
#[tauri::command]
pub(crate) async fn sign_in(managed: tauri::State<'_, Managed>) -> anyhow::Result<(), String> {
    if let Err(error) = managed.ctlr_tx.send(ControllerRequest::SignIn).await {
        tracing::error!(?error, "Couldn't request `Controller` to begin signing in");
    }
    Ok(())
}
