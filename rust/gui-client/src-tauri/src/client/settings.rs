//! Everything related to the Settings window, including
//! advanced settings and code for manipulating diagnostic logs.

use crate::client::gui::Managed;
use anyhow::Result;
use firezone_gui_client_common::{
    controller::{ControllerRequest, CtlrTx},
    settings::{save, AdvancedSettings},
};
use firezone_logging::std_dyn_err;
use std::time::Duration;
use tokio::sync::oneshot;

/// Saves the settings to disk and then applies them in-memory (except for logging)
#[tauri::command]
pub(crate) async fn apply_advanced_settings(
    managed: tauri::State<'_, Managed>,
    settings: AdvancedSettings,
) -> Result<(), String> {
    if managed.inner().inject_faults {
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    apply_inner(&managed.ctlr_tx, settings)
        .await
        .map_err(|e| e.to_string())?;

    Ok(())
}

#[tauri::command]
pub(crate) async fn reset_advanced_settings(
    managed: tauri::State<'_, Managed>,
) -> Result<AdvancedSettings, String> {
    let settings = AdvancedSettings::default();
    apply_advanced_settings(managed, settings.clone()).await?;
    Ok(settings)
}

/// Saves the settings to disk and then tells `Controller` to apply them in-memory
async fn apply_inner(ctlr_tx: &CtlrTx, settings: AdvancedSettings) -> Result<()> {
    save(&settings).await?;
    // TODO: Errors aren't handled here. But there isn't much that can go wrong
    // since it's just applying a new `Settings` object in memory.
    ctlr_tx
        .send(ControllerRequest::ApplySettings(Box::new(settings)))
        .await?;
    Ok(())
}

#[tauri::command]
pub(crate) async fn get_advanced_settings(
    managed: tauri::State<'_, Managed>,
) -> Result<AdvancedSettings, String> {
    let (tx, rx) = oneshot::channel();
    if let Err(error) = managed
        .ctlr_tx
        .send(ControllerRequest::GetAdvancedSettings(tx))
        .await
    {
        tracing::error!(
            error = std_dyn_err(&error),
            "couldn't request advanced settings from controller task"
        );
    }
    rx.await.map_err(|_| {
        "Couldn't get settings from `Controller`, maybe the program is crashing".to_string()
    })
}
