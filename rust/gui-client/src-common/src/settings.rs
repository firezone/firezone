//! Everything related to the Settings window, including
//! advanced settings and code for manipulating diagnostic logs.

use anyhow::{Context as _, Result};
use atomicwrites::{AtomicFile, OverwriteBehavior};
use connlib_model::ResourceId;
use firezone_headless_client::known_dirs;
use firezone_logging::std_dyn_err;
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, io::Write, path::PathBuf};
use url::Url;

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
            auth_base_url: Url::parse(defaults::AUTH_BASE_URL).unwrap(),
            api_url: Url::parse(defaults::API_URL).unwrap(),
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
    // Don't create the dir for the log filter file, that's the IPC service's job.
    // If it isn't there for some reason yet, just log an error and move on.
    let log_filter_path = known_dirs::ipc_log_filter().context("`ipc_log_filter` failed")?;
    let f = AtomicFile::new(&log_filter_path, OverwriteBehavior::AllowOverwrite);
    // Note: Blocking file write in async function
    if let Err(error) = f.write(|f| f.write_all(settings.log_filter.as_bytes())) {
        tracing::error!(
            error = std_dyn_err(&error),
            ?log_filter_path,
            "Couldn't write log filter file for IPC service"
        );
    }
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
