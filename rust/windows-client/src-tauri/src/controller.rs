use crate::prelude::*;
use tokio::sync::oneshot;

pub(crate) enum ControllerRequest {
    ExportLogs(PathBuf),
    GetAdvancedSettings(oneshot::Sender<AdvancedSettings>),
    // Secret because it will have the token in it
    SchemeRequest(SecretString),
    SignIn,
    UpdateResources(Vec<connlib_client_shared::ResourceDescription>),
}

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

impl AdvancedSettings {
    /// Gets the path for storing advanced settings, creating parent dirs if needed.
    pub async fn path() -> Result<PathBuf> {
        let dirs = crate::cli::get_project_dirs()?;
        let dir = dirs.config_local_dir();
        tokio::fs::create_dir_all(dir).await?;
        Ok(dir.join("advanced_settings.json"))
    }
}
