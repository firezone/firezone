//! App state. Pure data — no Controller wiring yet, so anything that would
//! normally come from the headless tunnel service is held as plain in-memory
//! state with stub defaults. Once `GuiIntegration` is implemented for iced
//! this will become the receive-side of a `mpsc::Sender<Message>`.

/// Top-level navigation route. Mirrors the React router's path set.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Route {
    #[default]
    Overview,
    GeneralSettings,
    AdvancedSettings,
    Diagnostics,
    About,
    /// Debug-only color palette page; only shown in the sidebar in
    /// debug builds, matching the React app's `isDev` gate.
    ColorPalette,
}

impl Route {
    pub fn title(self) -> &'static str {
        match self {
            Route::Overview => "Firezone",
            Route::GeneralSettings => "General Settings",
            Route::AdvancedSettings => "Advanced Settings",
            Route::Diagnostics => "Diagnostics",
            Route::About => "About",
            Route::ColorPalette => "Color Palette",
        }
    }
}

/// Same three-state machine as `gui-client/src-tauri/src/view.rs:SessionViewModel`.
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

/// Mirror of `logging.rs:FileCount`.
#[derive(Clone, Debug, Default)]
pub struct LogCount {
    pub bytes: u64,
    pub files: u64,
}

#[derive(Default)]
pub struct App {
    pub route: Route,
    pub session: Session,
    pub general_settings: GeneralSettingsState,
    pub advanced_settings: AdvancedSettingsState,
    pub log_count: LogCount,
}
