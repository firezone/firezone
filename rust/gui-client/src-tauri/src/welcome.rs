//! Everything related to the Welcome window

use crate::gui::Managed;
use anyhow::Context;

use super::controller::ControllerRequest;

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

#[tauri::command]
pub(crate) async fn sign_out(managed: tauri::State<'_, Managed>) -> Result<(), String> {
    managed
        .ctlr_tx
        .send(ControllerRequest::SignOut)
        .await
        .context("Failed to send `SignOut` command")
        .map_err(|e| e.to_string())?;

    Ok(())
}
