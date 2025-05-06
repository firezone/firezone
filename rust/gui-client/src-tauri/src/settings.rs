//! Everything related to the Settings window, including
//! advanced settings and code for manipulating diagnostic logs.

use crate::gui::Managed;
use anyhow::{Context as _, Result};
use connlib_model::ResourceId;
use firezone_bin_shared::known_dirs;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use std::{collections::HashSet, path::PathBuf};
use tokio::sync::oneshot;
use url::Url;

use super::controller::{ControllerRequest, CtlrTx};

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

    managed
        .ctlr_tx
        .send(ControllerRequest::GetAdvancedSettings(tx))
        .await
        .context("couldn't request advanced settings from controller task")
        .map_err(|e| e.to_string())?;

    rx.await.map_err(|_| {
        "Couldn't get settings from `Controller`, maybe the program is crashing".to_string()
    })
}

#[derive(Clone, Deserialize, Serialize)]
pub struct AdvancedSettings {
    pub auth_base_url: Url,
    pub api_url: Url,
    #[serde(default)]
    pub favorite_resources: HashSet<ResourceId>,
    #[serde(default)]
    pub internet_resource_enabled: Option<bool>,
    pub log_filter: String,
}

#[cfg(debug_assertions)]
mod defaults {
    pub(crate) const AUTH_BASE_URL: &str = "https://app.firez.one";
    pub(crate) const API_URL: &str = "wss://api.firez.one/";
    pub(crate) const LOG_FILTER: &str = "firezone_gui_client=debug,info";
}

#[cfg(not(debug_assertions))]
mod defaults {
    pub(crate) const AUTH_BASE_URL: &str = "https://app.firezone.dev";
    pub(crate) const API_URL: &str = "wss://api.firezone.dev/";
    pub(crate) const LOG_FILTER: &str = "info";
}

impl Default for AdvancedSettings {
    fn default() -> Self {
        Self {
            auth_base_url: Url::parse(defaults::AUTH_BASE_URL).expect("static URL is a valid URL"),
            api_url: Url::parse(defaults::API_URL).expect("static URL is a valid URL"),
            favorite_resources: Default::default(),
            internet_resource_enabled: Default::default(),
            log_filter: defaults::LOG_FILTER.to_string(),
        }
    }
}

impl AdvancedSettings {
    pub fn internet_resource_enabled(&self) -> bool {
        self.internet_resource_enabled.is_some_and(|v| v)
    }
}

pub fn advanced_settings_path() -> Result<PathBuf> {
    Ok(known_dirs::settings()
        .context("`known_dirs::settings` failed")?
        .join("advanced_settings.json"))
}

/// Saves the settings to disk
pub async fn save(settings: &AdvancedSettings) -> Result<()> {
    let path = advanced_settings_path()?;
    let dir = path
        .parent()
        .context("settings path should have a parent")?;

    tokio::fs::create_dir_all(dir).await?;
    tokio::fs::write(&path, serde_json::to_string(settings)?).await?;

    tracing::debug!(?path, "Saved settings");

    Ok(())
}

/// Return advanced settings if they're stored on disk
///
/// Uses std::fs, so stick it in `spawn_blocking` for async contexts
pub fn load_advanced_settings() -> Result<AdvancedSettings> {
    let path = advanced_settings_path()?;
    let text = std::fs::read_to_string(path)?;
    let settings = serde_json::from_str(&text)?;
    Ok(settings)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_old_formats() {
        let s = r#"{
            "auth_base_url": "https://example.com/",
            "api_url": "wss://example.com/",
            "log_filter": "info"
        }"#;

        let actual = serde_json::from_str::<AdvancedSettings>(s).unwrap();
        // Apparently the trailing slash here matters
        assert_eq!(actual.auth_base_url.to_string(), "https://example.com/");
        assert_eq!(actual.api_url.to_string(), "wss://example.com/");
        assert_eq!(actual.log_filter, "info");
    }
}
