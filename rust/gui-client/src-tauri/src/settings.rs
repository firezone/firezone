//! Everything related to the Settings window, including
//! advanced settings and code for manipulating diagnostic logs.

use anyhow::{Context as _, Result};
use connlib_model::ResourceId;
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, path::PathBuf};
use url::Url;

#[cfg(target_os = "linux")]
#[path = "settings/linux.rs"]
pub(crate) mod mdm;

#[cfg(target_os = "windows")]
#[path = "settings/windows.rs"]
pub(crate) mod mdm;

#[cfg(target_os = "macos")]
#[path = "settings/macos.rs"]
pub(crate) mod mdm;

pub use mdm::load_mdm_settings;

/// Defines all configuration options settable via MDM policies.
///
/// Configuring Firezone via MDM is optional, therefore all of these are [`Option`]s.
/// Some of the policies can simply be enabled but don't have a value themselves.
/// Those are modelled as [`Option<()>`].
///
/// Read exclusively by the privileged Tunnel service and delivered to the GUI
/// over IPC in the `Hello` message, so this needs to be (de)serializable.
#[derive(Clone, Default, Debug, Deserialize, Serialize)]
#[serde(default)]
pub struct MdmSettings {
    pub auth_url: Option<Url>,
    pub api_url: Option<Url>,
    pub log_filter: Option<String>,
    pub account_slug: Option<String>,
    pub hide_admin_portal_menu_item: Option<bool>,
    pub connect_on_start: Option<bool>,
    pub check_for_updates: Option<bool>,
    pub support_url: Option<Url>,
}

#[derive(Clone, Debug, Deserialize, Serialize, specta::Type)]
pub struct AdvancedSettings {
    pub auth_url: Url,
    pub api_url: Url,
    pub log_filter: String,
}

#[derive(Clone, Deserialize, Serialize, Default)]
pub struct GeneralSettings {
    #[serde(default)]
    pub favorite_resources: HashSet<ResourceId>,
    #[serde(default)]
    pub internet_resource_enabled: Option<bool>,
    #[serde(default = "start_minimized_default")]
    pub start_minimized: bool,
    #[serde(default)]
    pub start_on_login: Option<bool>,
    #[serde(default)]
    pub connect_on_start: Option<bool>,
    #[serde(default)]
    pub account_slug: Option<String>,
}

fn start_minimized_default() -> bool {
    true
}

#[derive(Clone, Serialize, specta::Type)]
pub struct GeneralSettingsViewModel {
    pub start_minimized: bool,
    pub start_on_login: bool,
    pub connect_on_start: bool,
    pub connect_on_start_is_managed: bool,
    pub account_slug: String,
    pub account_slug_is_managed: bool,
}

impl GeneralSettingsViewModel {
    pub fn new(mdm_settings: MdmSettings, general_settings: GeneralSettings) -> Self {
        Self {
            connect_on_start_is_managed: mdm_settings.connect_on_start.is_some(),
            account_slug_is_managed: mdm_settings.account_slug.is_some(),
            start_minimized: general_settings.start_minimized,
            start_on_login: general_settings.start_on_login.is_some_and(|v| v),
            connect_on_start: mdm_settings
                .connect_on_start
                .or(general_settings.connect_on_start)
                .is_some_and(|v| v),
            account_slug: mdm_settings
                .account_slug
                .or(general_settings.account_slug)
                .unwrap_or_default(),
        }
    }
}

#[derive(Clone, Serialize, specta::Type)]
pub struct AdvancedSettingsViewModel {
    pub auth_url: String,
    pub auth_url_is_managed: bool,
    pub api_url: String,
    pub api_url_is_managed: bool,
    pub log_filter: String,
    pub log_filter_is_managed: bool,
}

impl AdvancedSettingsViewModel {
    pub fn new(mdm_settings: MdmSettings, advanced_settings: AdvancedSettings) -> Self {
        Self {
            auth_url_is_managed: mdm_settings.auth_url.is_some(),
            api_url_is_managed: mdm_settings.api_url.is_some(),
            log_filter_is_managed: mdm_settings.log_filter.is_some(),

            auth_url: mdm_settings
                .auth_url
                .unwrap_or(advanced_settings.auth_url)
                .to_string(),
            api_url: mdm_settings
                .api_url
                .unwrap_or(advanced_settings.api_url)
                .to_string(),
            log_filter: mdm_settings
                .log_filter
                .unwrap_or(advanced_settings.log_filter),
        }
    }
}

#[cfg(debug_assertions)]
mod defaults {
    pub(crate) const AUTH_URL: &str = "https://app.firez.one";
    pub(crate) const API_URL: &str = "wss://api.firez.one/";
    pub(crate) const LOG_FILTER: &str = "debug";
}

#[cfg(not(debug_assertions))]
mod defaults {
    pub(crate) const AUTH_URL: &str = "https://app.firezone.dev";
    pub(crate) const API_URL: &str = "wss://api.firezone.dev/";
    pub(crate) const LOG_FILTER: &str = "info";
}

impl GeneralSettings {
    pub fn internet_resource_enabled(&self) -> bool {
        self.internet_resource_enabled.is_some_and(|v| v)
    }
}

impl Default for AdvancedSettings {
    fn default() -> Self {
        Self {
            auth_url: Url::parse(defaults::AUTH_URL).expect("static URL is a valid URL"),
            api_url: Url::parse(defaults::API_URL).expect("static URL is a valid URL"),
            log_filter: defaults::LOG_FILTER.to_string(),
        }
    }
}

pub fn general_settings_path() -> Result<PathBuf> {
    Ok(known_dirs::settings()
        .context("`known_dirs::settings` failed")?
        .join("general_settings.json"))
}

/// Saves the general settings to disk
pub async fn save_general(settings: &GeneralSettings) -> Result<()> {
    let path = general_settings_path()?;
    let dir = path
        .parent()
        .context("settings path should have a parent")?;

    tokio::fs::create_dir_all(dir).await?;
    tokio::fs::write(&path, serde_json::to_string(settings)?).await?;

    tracing::debug!(?path, "Saved settings");

    Ok(())
}

/// Return general settings if they're stored on disk
///
/// Uses std::fs, so stick it in `spawn_blocking` for async contexts
pub fn load_general_settings() -> Result<GeneralSettings> {
    let path = general_settings_path()?;
    let text = std::fs::read_to_string(path)?;
    let settings = serde_json::from_str(&text)?;
    Ok(settings)
}
