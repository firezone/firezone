//! Everything related to the Settings window, including
//! advanced settings and code for manipulating diagnostic logs.

use crate::client::gui::{self, ControllerRequest, Managed};
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

#[cfg(debug_assertions)]
impl Default for AdvancedSettings {
    fn default() -> Self {
        Self {
            auth_base_url: Url::parse("https://app.firez.one").unwrap(),
            api_url: Url::parse("wss://api.firez.one").unwrap(),
            log_filter: "firezone_windows_client=debug,firezone_tunnel=trace,connlib_shared=debug,connlib_client_shared=debug,warn".to_string(),
        }
    }
}

#[cfg(not(debug_assertions))]
impl Default for AdvancedSettings {
    fn default() -> Self {
        Self {
            auth_base_url: Url::parse("https://app.firezone.dev").unwrap(),
            api_url: Url::parse("wss://api.firezone.dev").unwrap(),
            log_filter: "firezone_windows_client=info,firezone_tunnel=trace,connlib_shared=info,connlib_client_shared=info,webrtc=error,warn".to_string(),
        }
    }
}

/// Returns the dir and path for storing advanced settings
fn advanced_settings_path(app: &tauri::AppHandle) -> Result<(PathBuf, PathBuf)> {
    let dir = gui::app_local_data_dir(app)?.0.join("config");
    let path = dir.join("advanced_settings.json");
    Ok((dir, path))
}

#[tauri::command]
pub(crate) async fn apply_advanced_settings(
    app: tauri::AppHandle,
    managed: tauri::State<'_, Managed>,
    settings: AdvancedSettings,
) -> StdResult<(), String> {
    apply_advanced_settings_inner(app, managed.inner(), settings)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub(crate) async fn get_advanced_settings(
    managed: tauri::State<'_, Managed>,
) -> StdResult<AdvancedSettings, String> {
    let (tx, rx) = oneshot::channel();
    if let Err(e) = managed
        .ctlr_tx
        .send(ControllerRequest::GetAdvancedSettings(tx))
        .await
    {
        tracing::error!("couldn't request advanced settings from controller task: {e}");
    }
    Ok(rx.await.unwrap())
}

pub(crate) async fn apply_advanced_settings_inner(
    app: tauri::AppHandle,
    managed: &Managed,
    settings: AdvancedSettings,
) -> Result<()> {
    let (dir, path) = advanced_settings_path(&app)?;
    tokio::fs::create_dir_all(&dir).await?;
    tokio::fs::write(path, serde_json::to_string(&settings)?).await?;

    if managed.inject_faults {
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    Ok(())
}

/// Return advanced settings if they're stored on disk
///
/// Uses std::fs, so stick it in `spawn_blocking` for async contexts
pub(crate) fn load_advanced_settings(app: &tauri::AppHandle) -> Result<AdvancedSettings> {
    let (_, path) = advanced_settings_path(app)?;
    let text = std::fs::read_to_string(path)?;
    let settings = serde_json::from_str(&text)?;
    Ok(settings)
}
