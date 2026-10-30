//! Everything related to the Settings window, including
//! advanced settings and code for manipulating diagnostic logs.

use anyhow::{Context as _, Result};
use connlib_model::ResourceId;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    net::IpAddr,
    path::{Path, PathBuf},
};
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

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct AdvancedSettings {
    // Installs from before the "General" settings split wrote `auth_base_url` to disk.
    #[serde(alias = "auth_base_url")]
    pub auth_url: Url,
    pub api_url: Url,
    pub log_filter: String,
    /// Set only through the CLI's `host-candidates`, so the settings page neither shows nor sends it.
    #[serde(default)]
    pub additional_host_candidates: Vec<IpAddr>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
pub struct AdvancedSettingsPatch {
    pub auth_url: Option<Url>,
    pub api_url: Option<Url>,
    pub log_filter: Option<String>,
}

impl AdvancedSettingsPatch {
    pub fn apply(self, mut settings: AdvancedSettings) -> AdvancedSettings {
        if let Some(auth_url) = self.auth_url {
            settings.auth_url = auth_url;
        }
        if let Some(api_url) = self.api_url {
            settings.api_url = api_url;
        }
        if let Some(log_filter) = self.log_filter {
            settings.log_filter = log_filter;
        }
        settings
    }

    pub fn is_empty(&self) -> bool {
        self.auth_url.is_none() && self.api_url.is_none() && self.log_filter.is_none()
    }
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
    /// The auth URL last saved with [`ControlPlane::Custom`], to prefill the field when it is picked again.
    #[serde(default)]
    pub custom_auth_url: Option<Url>,
    /// The API URL last saved with [`ControlPlane::Custom`], to prefill the field when it is picked again.
    #[serde(default)]
    pub custom_api_url: Option<Url>,
}

/// The account slug and control-plane URLs captured when sign-in started.
#[derive(Clone, Debug, serde::Deserialize, serde::Serialize, PartialEq, Eq)]
pub struct SignInSettings {
    pub account_slug: Option<String>,
    pub auth_url: Url,
    pub api_url: Url,
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
    pub control_plane: ControlPlane,
    pub auth_url: String,
    pub auth_url_is_managed: bool,
    pub api_url: String,
    pub api_url_is_managed: bool,
    /// What the auth URL field shows when [`ControlPlane::Custom`] is picked: the last saved custom URL, or else `auth_url`.
    pub custom_auth_url: String,
    /// What the API URL field shows when [`ControlPlane::Custom`] is picked: the last saved custom URL, or else `api_url`.
    pub custom_api_url: String,
    /// The settings captured when sign-in started, [`None`] when signed out.
    pub signed_in_with: Option<SignInSettingsViewModel>,
}

#[derive(Clone, Serialize, specta::Type)]
pub struct SignInSettingsViewModel {
    pub account_slug: String,
    pub control_plane: ControlPlane,
    pub auth_url: String,
    pub api_url: String,
}

impl GeneralSettingsViewModel {
    pub fn new(
        mdm_settings: MdmSettings,
        general_settings: GeneralSettings,
        advanced_settings: AdvancedSettings,
        signed_in_with: Option<SignInSettings>,
    ) -> Self {
        let auth_url_is_managed = mdm_settings.auth_url.is_some();
        let api_url_is_managed = mdm_settings.api_url.is_some();
        let auth_url = mdm_settings.auth_url.unwrap_or(advanced_settings.auth_url);
        let api_url = mdm_settings.api_url.unwrap_or(advanced_settings.api_url);

        // With only one of the URLs managed, `Custom` keeps the other one editable.
        let control_plane = if auth_url_is_managed == api_url_is_managed {
            ControlPlane::from_urls(&auth_url, &api_url)
        } else {
            ControlPlane::Custom
        };
        let custom_auth_url = general_settings
            .custom_auth_url
            .as_ref()
            .unwrap_or(&auth_url)
            .to_string();
        let custom_api_url = general_settings
            .custom_api_url
            .as_ref()
            .unwrap_or(&api_url)
            .to_string();

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
            control_plane,
            auth_url: auth_url.to_string(),
            auth_url_is_managed,
            api_url: api_url.to_string(),
            api_url_is_managed,
            custom_auth_url,
            custom_api_url,
            signed_in_with: signed_in_with.map(|signed_in_with| SignInSettingsViewModel {
                account_slug: signed_in_with.account_slug.unwrap_or_default(),
                control_plane: ControlPlane::from_urls(
                    &signed_in_with.auth_url,
                    &signed_in_with.api_url,
                ),
                auth_url: signed_in_with.auth_url.to_string(),
                api_url: signed_in_with.api_url.to_string(),
            }),
        }
    }
}

/// The control plane a client signs in to: a Firezone Cloud deployment, or [`ControlPlane::Custom`] for any other URLs.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize, specta::Type)]
pub enum ControlPlane {
    CloudUs,
    CloudEu,
    Custom,
}

impl ControlPlane {
    /// Returns the control plane whose URLs are exactly `auth_url` and `api_url`, or [`ControlPlane::Custom`].
    pub fn from_urls(auth_url: &Url, api_url: &Url) -> Self {
        [Self::CloudUs, Self::CloudEu]
            .into_iter()
            .find(|control_plane| {
                control_plane
                    .urls()
                    .is_some_and(|(auth, api)| &auth == auth_url && &api == api_url)
            })
            .unwrap_or(Self::Custom)
    }

    /// Returns the compiled-in auth and API URLs of the control plane, [`None`] for [`ControlPlane::Custom`].
    ///
    /// These are never taken from the control plane itself: they decide which control plane the client talks to.
    pub fn urls(self) -> Option<(Url, Url)> {
        let (auth_url, api_url) = match self {
            Self::CloudUs => (control_plane::US_AUTH_URL, control_plane::US_API_URL),
            Self::CloudEu => (control_plane::EU_AUTH_URL, control_plane::EU_API_URL),
            Self::Custom => return None,
        };

        Some((
            Url::parse(auth_url).expect("static URL is a valid URL"),
            Url::parse(api_url).expect("static URL is a valid URL"),
        ))
    }
}

mod control_plane {
    pub(crate) const US_AUTH_URL: &str = "https://app.firezone.dev";
    pub(crate) const US_API_URL: &str = "wss://api.firezone.dev/";
    pub(crate) const EU_AUTH_URL: &str = "https://eu.app.firezone.dev";
    pub(crate) const EU_API_URL: &str = "wss://eu.api.firezone.dev/";
}

#[derive(Clone, Serialize, specta::Type)]
pub struct LogFilterViewModel {
    pub log_filter: String,
    pub log_filter_is_managed: bool,
}

impl LogFilterViewModel {
    pub fn new(mdm_settings: MdmSettings, advanced_settings: AdvancedSettings) -> Self {
        Self {
            log_filter_is_managed: mdm_settings.log_filter.is_some(),
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
            additional_host_candidates: Vec::default(),
        }
    }
}

pub fn advanced_settings_path() -> Result<PathBuf> {
    Ok(known_dirs::tunnel_service_config()
        .context("`known_dirs::tunnel_service_config` failed")?
        .join("advanced_settings.json"))
}

pub fn general_settings_path() -> Result<PathBuf> {
    Ok(known_dirs::settings()
        .context("`known_dirs::settings` failed")?
        .join("general_settings.json"))
}

/// Saves the advanced settings to disk
///
/// Owned exclusively by the privileged Tunnel service. The file lives in
/// `tunnel_service_config()` with restrictive permissions so that other
/// processes running as the same desktop user cannot rewrite values like
/// `auth_url` to redirect the next sign-in to an attacker-controlled backend.
pub async fn save_advanced(settings: &AdvancedSettings) -> Result<()> {
    let path = advanced_settings_path()?;
    let dir = path
        .parent()
        .context("settings path should have a parent")?;

    tokio::fs::create_dir_all(dir).await?;
    set_dir_permissions(dir)?;
    tokio::fs::write(&path, serde_json::to_string(settings)?).await?;
    set_file_permissions(&path)?;

    tracing::debug!(?path, "Saved settings");

    Ok(())
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

/// Return advanced settings if they're stored on disk
///
/// Uses std::fs, so stick it in `spawn_blocking` for async contexts
pub fn load_advanced_settings() -> Result<AdvancedSettings> {
    let path = advanced_settings_path()?;
    let text = std::fs::read_to_string(path)?;
    let settings = serde_json::from_str(&text)?;
    Ok(settings)
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

#[cfg(target_os = "linux")]
fn set_dir_permissions(dir: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt as _;
    // Owner rwx, `firezone-client` group rx, others none. The group also
    // owns the device-id file in the same directory, which the GUI reads
    // directly; group write would let any group member replace files
    // under the dir, defeating the protected-storage goal.
    let perms = std::fs::Permissions::from_mode(0o750);
    std::fs::set_permissions(dir, perms)?;
    Ok(())
}

/// Protected DACL for the Tunnel service config directory, mirroring
/// `bin_shared::device_id`: Full Access to LocalSystem and
/// `BUILTIN\Administrators`, with Object + Container inheritance so the
/// ACEs propagate to child files (notably the device-id file) and
/// subdirectories.
#[cfg(target_os = "windows")]
fn set_dir_permissions(dir: &Path) -> Result<()> {
    use windows_security::pipe_dacl::{FileRights, PipeDacl, Trustee};
    PipeDacl::new()
        .allow_inheriting(FileRights::FullAccess, Trustee::local_system())
        .allow_inheriting(FileRights::FullAccess, Trustee::builtin_administrators())
        .build()?
        .apply_to_path(dir)
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
#[expect(clippy::unnecessary_wraps)]
fn set_dir_permissions(_: &Path) -> Result<()> {
    Ok(())
}

#[cfg(target_os = "linux")]
fn set_file_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt as _;
    // Owner rw, group nothing, others nothing. Stricter than `firezone-id.json`
    // (`0o640`) because the GUI never reads this file -- it receives the values
    // over IPC.
    let perms = std::fs::Permissions::from_mode(0o600);
    std::fs::set_permissions(path, perms)?;
    Ok(())
}

#[cfg(target_os = "windows")]
fn set_file_permissions(path: &Path) -> Result<()> {
    windows_security::SecurityDescriptor::from_sddl(FILE_SDDL)?.apply_to_path(path)
}

/// SDDL for the on-disk `advanced_settings.json` file.
///
/// `D:P(A;;FA;;;SY)(A;;FA;;;BA)` -- protected DACL, Full Access to
/// LocalSystem and BUILTIN\Administrators only.
#[cfg(target_os = "windows")]
const FILE_SDDL: &str = "D:P(A;;FA;;;SY)(A;;FA;;;BA)";

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
#[expect(clippy::unnecessary_wraps)]
fn set_file_permissions(_: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn independent_patches_preserve_other_saved_settings() {
        let candidates = vec![IpAddr::from([192, 168, 2, 1])];
        let mut saved = AdvancedSettings {
            additional_host_candidates: candidates.clone(),
            ..Default::default()
        };
        for patch in [
            AdvancedSettingsPatch {
                auth_url: Some(Url::parse("https://auth.example.com").unwrap()),
                ..Default::default()
            },
            AdvancedSettingsPatch {
                api_url: Some(Url::parse("wss://api.example.com").unwrap()),
                ..Default::default()
            },
            AdvancedSettingsPatch {
                log_filter: Some("trace".to_owned()),
                ..Default::default()
            },
        ] {
            saved = patch.apply(saved);
        }
        assert_eq!(saved.auth_url.as_str(), "https://auth.example.com/");
        assert_eq!(saved.api_url.as_str(), "wss://api.example.com/");
        assert_eq!(saved.log_filter, "trace");
        assert_eq!(saved.additional_host_candidates, candidates);
    }

    #[test]
    fn saved_us_urls_show_firezone_cloud_us() {
        let view_model = view_model(
            MdmSettings::default(),
            advanced_settings("https://app.firezone.dev", "wss://api.firezone.dev"),
        );

        assert_eq!(view_model.control_plane, ControlPlane::CloudUs);
    }

    #[test]
    fn saved_self_hosted_urls_show_custom() {
        let view_model = view_model(
            MdmSettings::default(),
            advanced_settings("https://firezone.example.com", "wss://api.example.com"),
        );

        assert_eq!(view_model.control_plane, ControlPlane::Custom);
        assert_eq!(view_model.auth_url, "https://firezone.example.com/");
        assert_eq!(view_model.api_url, "wss://api.example.com/");
    }

    #[test]
    fn managed_eu_urls_override_saved_urls() {
        let mdm_settings = MdmSettings {
            auth_url: Some(Url::parse("https://eu.app.firezone.dev").unwrap()),
            api_url: Some(Url::parse("wss://eu.api.firezone.dev").unwrap()),
            ..Default::default()
        };

        let view_model = view_model(
            mdm_settings,
            advanced_settings("https://app.firezone.dev", "wss://api.firezone.dev"),
        );

        assert_eq!(view_model.control_plane, ControlPlane::CloudEu);
        assert!(view_model.auth_url_is_managed);
        assert!(view_model.api_url_is_managed);
    }

    #[test]
    fn managed_urls_match_a_control_plane_despite_trivial_differences() {
        let mdm_settings = MdmSettings {
            auth_url: Some(Url::parse("HTTPS://EU.APP.FIREZONE.DEV:443/").unwrap()),
            api_url: Some(Url::parse("wss://eu.api.firezone.dev").unwrap()),
            ..Default::default()
        };

        let view_model = view_model(
            mdm_settings,
            advanced_settings("https://app.firezone.dev", "wss://api.firezone.dev"),
        );

        assert_eq!(view_model.control_plane, ControlPlane::CloudEu);
    }

    #[test]
    fn one_managed_url_shows_custom() {
        let mdm_settings = MdmSettings {
            api_url: Some(Url::parse("wss://api.firezone.dev").unwrap()),
            ..Default::default()
        };

        let view_model = view_model(
            mdm_settings,
            advanced_settings("https://app.firezone.dev", "wss://api.firezone.dev"),
        );

        assert_eq!(view_model.control_plane, ControlPlane::Custom);
    }

    #[test]
    fn custom_fields_fall_back_to_the_current_urls() {
        let view_model = view_model(
            MdmSettings::default(),
            advanced_settings("https://app.firezone.dev", "wss://api.firezone.dev"),
        );

        assert_eq!(view_model.custom_auth_url, "https://app.firezone.dev/");
        assert_eq!(view_model.custom_api_url, "wss://api.firezone.dev/");
    }

    #[test]
    fn custom_fields_show_the_last_saved_custom_urls() {
        let general_settings = GeneralSettings {
            custom_auth_url: Some(Url::parse("https://firezone.example.com").unwrap()),
            custom_api_url: Some(Url::parse("wss://api.example.com").unwrap()),
            ..Default::default()
        };

        let view_model = GeneralSettingsViewModel::new(
            MdmSettings::default(),
            general_settings,
            advanced_settings("https://eu.app.firezone.dev", "wss://eu.api.firezone.dev"),
            None,
        );

        assert_eq!(view_model.control_plane, ControlPlane::CloudEu);
        assert_eq!(view_model.custom_auth_url, "https://firezone.example.com/");
        assert_eq!(view_model.custom_api_url, "wss://api.example.com/");
    }

    #[test]
    fn signed_in_with_names_the_control_plane_it_signed_in_to() {
        let view_model = GeneralSettingsViewModel::new(
            MdmSettings::default(),
            GeneralSettings::default(),
            advanced_settings("https://app.firezone.dev", "wss://api.firezone.dev"),
            Some(SignInSettings {
                account_slug: None,
                auth_url: Url::parse("https://eu.app.firezone.dev").unwrap(),
                api_url: Url::parse("wss://eu.api.firezone.dev").unwrap(),
            }),
        );

        let signed_in_with = view_model.signed_in_with.unwrap();
        assert_eq!(signed_in_with.control_plane, ControlPlane::CloudEu);
        assert_eq!(signed_in_with.account_slug, "");
    }

    fn view_model(
        mdm_settings: MdmSettings,
        advanced_settings: AdvancedSettings,
    ) -> GeneralSettingsViewModel {
        GeneralSettingsViewModel::new(
            mdm_settings,
            GeneralSettings::default(),
            advanced_settings,
            None,
        )
    }

    fn advanced_settings(auth_url: &str, api_url: &str) -> AdvancedSettings {
        AdvancedSettings {
            auth_url: Url::parse(auth_url).unwrap(),
            api_url: Url::parse(api_url).unwrap(),
            log_filter: "info".to_owned(),
            additional_host_candidates: Vec::default(),
        }
    }
}
