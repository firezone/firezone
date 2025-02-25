//! Everything related to the Welcome window

use crate::client::gui::Managed;
use anyhow::Context;
use firezone_gui_client_common::controller::ControllerRequest;

#[tauri::command]
pub(crate) async fn sign_in(managed: tauri::State<'_, Managed>) -> Result<(), String> {
    managed
        .ctlr_tx
        .send(ControllerRequest::SignIn)
        .await
        .context("Failed to send `SignIn` command")
        .map_err(|e| e.to_string())?;

    Ok(())
}
