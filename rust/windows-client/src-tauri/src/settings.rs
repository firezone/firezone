//! Everything related to the Settings window, including
//! advanced settings and code for manipulating diagnostic logs.

use crate::gui::{ControllerRequest, CtlrTx};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, result::Result as StdResult, time::Duration};
use tokio::sync::oneshot;
use url::Url;

#[derive(Clone, Deserialize, Serialize)]
pub(crate) struct AdvancedSettings {
    pub auth_base_url: Url,
    pub api_url: Url,
    pub log_filter: String,
}

impl Default for AdvancedSettings {
    fn default() -> Self {
        Self {
            auth_base_url: Url::parse("https://app.firezone.dev").unwrap(),
            api_url: Url::parse("wss://api.firezone.dev").unwrap(),
            log_filter: "info".to_string(),
        }
    }
}

/// Gets the path for storing advanced settings, creating parent dirs if needed.
pub(crate) async fn advanced_settings_path(app: &tauri::AppHandle) -> Result<PathBuf> {
    let dir = app
        .path_resolver()
        .app_local_data_dir()
        .ok_or_else(|| anyhow::anyhow!("can't get app_local_data_dir"))?
        .join("config");
    tokio::fs::create_dir_all(&dir).await?;
    Ok(dir.join("advanced_settings.json"))
}

#[tauri::command]
pub(crate) async fn apply_advanced_settings(
    app: tauri::AppHandle,
    settings: AdvancedSettings,
) -> StdResult<(), String> {
    apply_advanced_settings_inner(app, settings)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub(crate) async fn clear_logs() -> StdResult<(), String> {
    clear_logs_inner().await.map_err(|e| format!("{e}"))
}

#[tauri::command]
pub(crate) async fn export_logs(ctlr_tx: tauri::State<'_, CtlrTx>) -> StdResult<(), String> {
    export_logs_inner(ctlr_tx.inner().clone())
        .await
        .map_err(|e| format!("{e}"))
}

#[tauri::command]
pub(crate) async fn get_advanced_settings(
    ctlr_tx: tauri::State<'_, CtlrTx>,
) -> StdResult<AdvancedSettings, String> {
    let (tx, rx) = oneshot::channel();
    ctlr_tx
        .send(ControllerRequest::GetAdvancedSettings(tx))
        .await
        .unwrap();
    Ok(rx.await.unwrap())
}

pub(crate) async fn apply_advanced_settings_inner(
    app: tauri::AppHandle,
    settings: AdvancedSettings,
) -> Result<()> {
    tokio::fs::write(
        advanced_settings_path(&app).await?,
        serde_json::to_string(&settings)?,
    )
    .await?;

    // TODO: This sleep is just for testing, remove it before it ships
    // TODO: Make sure the GUI handles errors if this function fails
    tokio::time::sleep(Duration::from_secs(1)).await;
    Ok(())
}

pub(crate) async fn load_advanced_settings(app: &tauri::AppHandle) -> Result<AdvancedSettings> {
    let path = advanced_settings_path(app).await?;
    let text = tokio::fs::read_to_string(&path).await?;
    let settings = serde_json::from_str(&text)?;
    Ok(settings)
}

pub(crate) async fn clear_logs_inner() -> Result<()> {
    todo!()
}

pub(crate) async fn export_logs_inner(ctlr_tx: CtlrTx) -> Result<()> {
    tauri::api::dialog::FileDialogBuilder::new()
        .add_filter("Zip", &["zip"])
        .save_file(move |file_path| match file_path {
            None => {}
            Some(x) => ctlr_tx
                .blocking_send(ControllerRequest::ExportLogs(x))
                .unwrap(),
        });
    Ok(())
}

pub(crate) async fn export_logs_to(file_path: PathBuf) -> Result<()> {
    tracing::trace!("Exporting logs to {file_path:?}");

    let mut entries = tokio::fs::read_dir("logs").await?;
    while let Some(entry) = entries.next_entry().await? {
        let path = entry.path();
        tracing::trace!("Export {path:?}");
    }
    tokio::time::sleep(Duration::from_secs(1)).await;
    // TODO: Somehow signal back to the GUI to unlock the log buttons when the export completes, or errors out
    Ok(())
}
