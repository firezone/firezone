//! App state for the xilem GUI. Mirrors `crate::iced::state`, but drops the
//! iced-specific `Animation<bool>` toggle fields (xilem has its own animation
//! story, unused in this first cut) and the iced `window::Id` (the first cut
//! runs a single always-open window via `Xilem::new_simple`).

use crate::controller::ControllerRequest;
use crate::logging::FileCount;
use crate::settings::{AdvancedSettings, GeneralSettings, MdmSettings};
use tokio::sync::mpsc;
use url::Url;

/// Top-level navigation route. Mirrors the React router's path set.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Route {
    #[default]
    Overview,
    GeneralSettings,
    AdvancedSettings,
    Diagnostics,
    About,
}

/// Same three-state machine as `view.rs:SessionViewModel`.
#[derive(Clone, Debug, Default)]
pub enum Session {
    #[default]
    SignedOut,
    Loading,
    SignedIn {
        account_slug: String,
        actor_name: String,
    },
}

/// In-memory mirror of `settings.rs:GeneralSettings` / `GeneralSettingsViewModel`.
#[derive(Clone, Debug)]
pub struct GeneralSettingsState {
    pub account_slug: String,
    pub start_minimized: bool,
    pub start_on_login: bool,
    pub connect_on_start: bool,
    pub account_slug_is_managed: bool,
    pub connect_on_start_is_managed: bool,
}

impl Default for GeneralSettingsState {
    fn default() -> Self {
        Self {
            account_slug: String::new(),
            start_minimized: true,
            start_on_login: false,
            connect_on_start: false,
            account_slug_is_managed: false,
            connect_on_start_is_managed: false,
        }
    }
}

/// In-memory mirror of `settings.rs:AdvancedSettings` / `AdvancedSettingsViewModel`.
#[derive(Clone, Debug)]
pub struct AdvancedSettingsState {
    pub auth_url: String,
    pub api_url: String,
    pub log_filter: String,
    pub auth_url_is_managed: bool,
    pub api_url_is_managed: bool,
    pub log_filter_is_managed: bool,
}

impl Default for AdvancedSettingsState {
    fn default() -> Self {
        Self {
            auth_url: "https://app.firezone.dev/".to_owned(),
            api_url: "wss://api.firezone.dev/".to_owned(),
            log_filter: "info".to_owned(),
            auth_url_is_managed: false,
            api_url_is_managed: false,
            log_filter_is_managed: false,
        }
    }
}

impl GeneralSettingsState {
    pub fn from_settings(mdm: &MdmSettings, general: &GeneralSettings) -> Self {
        let start_minimized = general.start_minimized;
        let start_on_login = general.start_on_login.unwrap_or(false);
        let connect_on_start = mdm
            .connect_on_start
            .or(general.connect_on_start)
            .unwrap_or(false);
        Self {
            account_slug: mdm
                .account_slug
                .clone()
                .or_else(|| general.account_slug.clone())
                .unwrap_or_default(),
            start_minimized,
            start_on_login,
            connect_on_start,
            account_slug_is_managed: mdm.account_slug.is_some(),
            connect_on_start_is_managed: mdm.connect_on_start.is_some(),
        }
    }

    /// Convert back to the on-disk `GeneralSettings` shape. The
    /// `favorite_resources` and `internet_resource_enabled` fields aren't
    /// editable from this screen, so we preserve them from the
    /// previously-loaded settings (passed in as `previous`).
    pub fn to_settings(&self, previous: &GeneralSettings) -> GeneralSettings {
        GeneralSettings {
            favorite_resources: previous.favorite_resources.clone(),
            internet_resource_enabled: previous.internet_resource_enabled,
            start_minimized: self.start_minimized,
            start_on_login: Some(self.start_on_login),
            connect_on_start: Some(self.connect_on_start),
            account_slug: if self.account_slug.is_empty() {
                None
            } else {
                Some(self.account_slug.clone())
            },
        }
    }
}

impl AdvancedSettingsState {
    pub fn from_settings(mdm: &MdmSettings, advanced: &AdvancedSettings) -> Self {
        Self {
            auth_url: mdm
                .auth_url
                .clone()
                .map(|u| u.to_string())
                .unwrap_or_else(|| advanced.auth_url.to_string()),
            api_url: mdm
                .api_url
                .clone()
                .map(|u| u.to_string())
                .unwrap_or_else(|| advanced.api_url.to_string()),
            log_filter: mdm
                .log_filter
                .clone()
                .unwrap_or_else(|| advanced.log_filter.clone()),
            auth_url_is_managed: mdm.auth_url.is_some(),
            api_url_is_managed: mdm.api_url.is_some(),
            log_filter_is_managed: mdm.log_filter.is_some(),
        }
    }

    /// Convert back to the on-disk `AdvancedSettings`. Returns `None` if
    /// either URL fails to parse.
    pub fn to_settings(&self) -> Option<AdvancedSettings> {
        Some(AdvancedSettings {
            auth_url: Url::parse(&self.auth_url).ok()?,
            api_url: Url::parse(&self.api_url).ok()?,
            log_filter: self.log_filter.clone(),
        })
    }
}

/// Mirror of `logging.rs:FileCount`.
#[derive(Clone, Debug, Default)]
pub struct LogCount {
    pub bytes: u64,
    pub files: u64,
}

impl From<FileCount> for LogCount {
    fn from(value: FileCount) -> Self {
        // FileCount fields are private; round-trip via serde_json which
        // exposes `bytes` and `files`.
        let v = serde_json::to_value(&value).unwrap_or_default();
        Self {
            bytes: v.get("bytes").and_then(|x| x.as_u64()).unwrap_or_default(),
            files: v.get("files").and_then(|x| x.as_u64()).unwrap_or_default(),
        }
    }
}

#[derive(Default)]
pub struct App {
    pub route: Route,
    pub session: Session,
    pub general_settings: GeneralSettingsState,
    pub advanced_settings: AdvancedSettingsState,
    pub log_count: LogCount,
    /// The last `GeneralSettings` we read from disk; used as the merge-base
    /// when converting `GeneralSettingsState` back for persistence.
    pub general_settings_disk: GeneralSettings,
    /// MDM settings loaded at startup. Managed fields stay non-editable.
    pub mdm_settings: MdmSettings,
    /// Sender into the Controller's request channel. Populated by the bridge
    /// `worker`'s `store_sender` on the first build; `None` until then.
    pub ctrl_tx: Option<mpsc::UnboundedSender<ControllerRequest>>,
}
