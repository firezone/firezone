use std::{path::PathBuf, time::Duration};

use anyhow::{Context as _, Result};
use logging::err_with_src;
use serde::Serialize;
use tauri_plugin_dialog::{DialogExt as _, MessageDialogButtons, MessageDialogKind};

use crate::{
    controller::ControllerRequest,
    gui::Managed,
    logging::FileCount,
    settings::{
        AdvancedSettings, GeneralSettings, GeneralSettingsViewModel, LogFilterViewModel,
        MdmSettings, Portal,
    },
};
use url::Url;

#[derive(Clone, Default, serde::Deserialize, specta::Type)]
pub struct GeneralSettingsForm {
    #[serde(default)]
    pub start_minimized: Option<bool>,
    #[serde(default)]
    pub start_on_login: Option<bool>,
    #[serde(default)]
    pub connect_on_start: Option<bool>,
    #[serde(default)]
    pub account_slug: Option<String>,
    #[serde(default)]
    pub portal: Option<Portal>,
    /// Only used for [`Portal::Custom`].
    #[serde(default)]
    pub auth_url: Option<String>,
    /// Only used for [`Portal::Custom`].
    #[serde(default)]
    pub api_url: Option<String>,
}

impl GeneralSettingsForm {
    /// Returns `general_settings` and `advanced_settings` with the form's values applied.
    ///
    /// A managed URL wins over the saved one, so the form leaves it alone. Saving with
    /// [`Portal::Custom`] also remembers the URLs for the next time it is picked.
    pub fn apply(
        self,
        mdm_settings: &MdmSettings,
        general_settings: GeneralSettings,
        advanced_settings: AdvancedSettings,
    ) -> Result<(GeneralSettings, AdvancedSettings)> {
        let portal = self.portal.unwrap_or_else(|| {
            Portal::from_urls(&advanced_settings.auth_url, &advanced_settings.api_url)
        });
        let (auth_url, api_url) = self.urls(&advanced_settings)?;
        let mut general_settings = general_settings;
        if let Some(start_minimized) = self.start_minimized {
            general_settings.start_minimized = start_minimized;
        }
        if let Some(start_on_login) = self.start_on_login {
            general_settings.start_on_login = Some(start_on_login);
        }
        if let Some(connect_on_start) = self.connect_on_start {
            general_settings.connect_on_start = Some(connect_on_start);
        }
        if let Some(account_slug) = self.account_slug {
            let account_slug = account_slug.trim();
            general_settings.account_slug =
                (!account_slug.is_empty()).then(|| account_slug.to_owned());
        }
        if portal == Portal::Custom {
            general_settings.custom_auth_url = Some(auth_url.clone());
            general_settings.custom_api_url = Some(api_url.clone());
        } else if Portal::from_urls(&advanced_settings.auth_url, &advanced_settings.api_url)
            == Portal::Custom
        {
            general_settings.custom_auth_url = Some(advanced_settings.auth_url.clone());
            general_settings.custom_api_url = Some(advanced_settings.api_url.clone());
        }

        let advanced_settings = AdvancedSettings {
            auth_url: match mdm_settings.auth_url {
                Some(_) => advanced_settings.auth_url,
                None => auth_url,
            },
            api_url: match mdm_settings.api_url {
                Some(_) => advanced_settings.api_url,
                None => api_url,
            },
            log_filter: advanced_settings.log_filter,
            additional_host_candidates: advanced_settings.additional_host_candidates,
        };

        Ok((general_settings, advanced_settings))
    }

    /// Returns the auth and API URLs of the selected portal, or the typed ones for [`Portal::Custom`].
    pub fn urls(&self, current: &AdvancedSettings) -> Result<(Url, Url)> {
        if let Some(urls) = self.portal.and_then(Portal::urls) {
            return Ok(urls);
        }

        Ok((
            parse_url(
                self.auth_url
                    .as_deref()
                    .unwrap_or(current.auth_url.as_str()),
                &["http", "https"],
            )
            .context("Invalid auth URL")?,
            parse_url(
                self.api_url.as_deref().unwrap_or(current.api_url.as_str()),
                &["ws", "wss"],
            )
            .context("Invalid API URL")?,
        ))
    }
}

fn parse_url(value: &str, schemes: &[&str]) -> Result<Url> {
    let url = Url::parse(value)?;

    anyhow::ensure!(url.has_host(), "URL has no host");
    anyhow::ensure!(
        schemes.contains(&url.scheme()),
        "URL scheme must be one of {schemes:?}"
    );

    Ok(url)
}

#[derive(Clone, Debug, serde::Serialize, specta::Type, PartialEq, Eq)]
pub enum SessionViewModel {
    SignedIn {
        account_slug: String,
        actor_name: String,
    },
    Loading,
    SignedOut,
}

#[derive(Clone, serde::Serialize, specta::Type, tauri_specta::Event)]
pub struct SessionChanged(pub SessionViewModel);

#[derive(Clone, serde::Serialize, specta::Type, tauri_specta::Event)]
pub struct GeneralSettingsChanged(pub GeneralSettingsViewModel);

#[derive(Clone, serde::Serialize, specta::Type, tauri_specta::Event)]
pub struct LogFilterChanged(pub LogFilterViewModel);

#[derive(Clone, serde::Serialize, specta::Type, tauri_specta::Event)]
pub struct LogsRecounted(pub FileCount);

/// The platform keystore's certificate as the device trust page renders it.
#[derive(Clone, serde::Serialize, specta::Type, tauri_specta::Event)]
pub struct X509CertificateChanged(pub Option<X509Certificate>);

/// A certificate the Tunnel service loaded from the platform keystore.
#[derive(Clone, serde::Serialize, specta::Type)]
pub struct X509Certificate {
    pub fields: Vec<X509DetailField>,
}

/// A label-value row of the certificate, and what is wrong with it.
#[derive(Clone, serde::Serialize, specta::Type)]
pub struct X509DetailField {
    pub label: String,
    /// What the row carries, [`None`] when it carries nothing.
    pub value: Option<String>,
    /// Why the value is not usable as what the row names, [`None`] when it is.
    pub problem: Option<X509ValidationError>,
}

/// Mirrors [`x509_keystore::ValidationError`].
#[derive(Clone, serde::Serialize, specta::Type)]
pub enum X509ValidationError {
    Empty,
    TooLong,
    Ambiguous,
    PlaceholderIdentifier,
    UnknownAttribute,
    NotYetValid,
    Expired,
    MissingClientAuthEku,
    DigitalSignatureNotAllowed,
}

impl From<Option<&x509_keystore::ParsedCertificate>> for X509CertificateChanged {
    fn from(certificate: Option<&x509_keystore::ParsedCertificate>) -> Self {
        Self(certificate.map(X509Certificate::from))
    }
}

impl From<&x509_keystore::ParsedCertificate> for X509Certificate {
    fn from(certificate: &x509_keystore::ParsedCertificate) -> Self {
        Self {
            fields: certificate
                .detail_fields()
                .into_iter()
                .map(X509DetailField::from)
                .collect(),
        }
    }
}

impl From<x509_keystore::DetailField> for X509DetailField {
    fn from(field: x509_keystore::DetailField) -> Self {
        Self {
            label: field.label,
            value: field.value,
            problem: field.problem.map(X509ValidationError::from),
        }
    }
}

impl From<x509_keystore::ValidationError> for X509ValidationError {
    fn from(error: x509_keystore::ValidationError) -> Self {
        match error {
            x509_keystore::ValidationError::Empty => Self::Empty,
            x509_keystore::ValidationError::TooLong => Self::TooLong,
            x509_keystore::ValidationError::Ambiguous => Self::Ambiguous,
            x509_keystore::ValidationError::PlaceholderIdentifier => Self::PlaceholderIdentifier,
            x509_keystore::ValidationError::UnknownAttribute => Self::UnknownAttribute,
            x509_keystore::ValidationError::NotYetValid => Self::NotYetValid,
            x509_keystore::ValidationError::Expired => Self::Expired,
            x509_keystore::ValidationError::MissingClientAuthEku => Self::MissingClientAuthEku,
            x509_keystore::ValidationError::DigitalSignatureNotAllowed => {
                Self::DigitalSignatureNotAllowed
            }
        }
    }
}

#[tauri::command]
#[specta::specta]
pub async fn clear_logs(
    window: tauri::WebviewWindow,
    managed: tauri::State<'_, Managed>,
) -> Result<(), Error> {
    let (confirm_tx, confirm_rx) = tokio::sync::oneshot::channel();

    window
        .dialog()
        .message(
            "This deletes all log files on this device. Export them first if you need them for a support request.",
        )
        .title("Clear log files?")
        .kind(MessageDialogKind::Warning)
        .buttons(MessageDialogButtons::OkCancelCustom(
            "Clear".to_owned(),
            "Cancel".to_owned(),
        ))
        .parent(&window)
        .show(|confirmed| {
            let _ = confirm_tx.send(confirmed);
        });

    if !confirm_rx.await.unwrap_or(false) {
        return Ok(());
    }

    let (tx, rx) = tokio::sync::oneshot::channel();

    managed
        .send_request(ControllerRequest::ClearLogs(tx))
        .await?;

    rx.await
        .context("Failed to await `ClearLogs` result")?
        .map_err(anyhow::Error::msg)?;

    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn export_logs(
    app: tauri::AppHandle,
    managed: tauri::State<'_, Managed>,
) -> Result<(), Error> {
    show_export_dialog(&app, managed.inner().clone())?;

    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn apply_general_settings(
    managed: tauri::State<'_, Managed>,
    settings: GeneralSettingsForm,
) -> Result<(), Error> {
    if managed.inner().inject_faults {
        tokio::time::sleep(Duration::from_secs(2)).await;
    }

    managed
        .send_request(ControllerRequest::ApplyGeneralSettings(Box::new(settings)))
        .await?;

    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn apply_log_filter(
    managed: tauri::State<'_, Managed>,
    log_filter: String,
) -> Result<(), Error> {
    check_log_filter(&log_filter)?;

    if managed.inner().inject_faults {
        tokio::time::sleep(Duration::from_secs(2)).await;
    }

    managed
        .send_request(ControllerRequest::ApplyLogFilter(log_filter))
        .await?;

    Ok(())
}

fn check_log_filter(log_filter: &str) -> Result<(), Error> {
    logging::try_filter::<tracing_subscriber::Registry>(log_filter)
        .map_err(|e| Error(format!("Invalid log filter: {e}")))?;

    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn reset_general_settings(
    window: tauri::WebviewWindow,
    managed: tauri::State<'_, Managed>,
) -> Result<(), Error> {
    let (tx, rx) = tokio::sync::oneshot::channel();

    window
        .dialog()
        .message("Reset settings to defaults?")
        .kind(MessageDialogKind::Warning)
        .buttons(MessageDialogButtons::OkCancelCustom(
            "Reset".to_owned(),
            "Cancel".to_owned(),
        ))
        .parent(&window)
        .show(|confirmed| {
            let _ = tx.send(confirmed);
        });

    if !rx.await.unwrap_or(false) {
        return Ok(());
    }

    managed
        .send_request(ControllerRequest::ResetGeneralSettings)
        .await?;

    Ok(())
}

/// Pops up the "Save File" dialog
fn show_export_dialog(app: &tauri::AppHandle, managed: Managed) -> Result<(), Error> {
    let now = chrono::Local::now();
    let datetime_string = now.format("%Y_%m_%d-%H-%M");
    let stem = PathBuf::from(format!("firezone_logs_{datetime_string}"));
    let filename = stem.with_extension("zip");
    let filename = filename
        .to_str()
        .context("zip filename isn't valid Unicode")?;

    tauri_plugin_dialog::FileDialogBuilder::new(app.dialog().clone())
        .add_filter("Zip", &["zip"])
        .set_file_name(filename)
        .save_file(move |file_path| {
            let Some(file_path) = file_path else {
                return;
            };

            let path = match file_path.clone().into_path() {
                Ok(path) => path,
                Err(e) => {
                    tracing::warn!(%file_path, "Invalid file path: {}", err_with_src(&e));
                    return;
                }
            };

            // blocking_send here because we're in a sync callback within Tauri somewhere
            if let Err(e) =
                managed.blocking_send_request(ControllerRequest::ExportLogs { path, stem })
            {
                tracing::warn!("{e:#}");
            }
        });
    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn sign_in(managed: tauri::State<'_, Managed>) -> Result<(), Error> {
    managed.send_request(ControllerRequest::SignIn).await?;

    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn sign_out(managed: tauri::State<'_, Managed>) -> Result<(), Error> {
    managed.send_request(ControllerRequest::SignOut).await?;

    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn update_state(managed: tauri::State<'_, Managed>) -> Result<(), Error> {
    managed.send_request(ControllerRequest::UpdateState).await?;

    Ok(())
}

#[derive(Debug, specta::Type, Serialize)]
pub struct Error(String);

impl From<anyhow::Error> for Error {
    fn from(error: anyhow::Error) -> Self {
        Self(format!("{error:#}"))
    }
}

/// The tauri-specta registry of every command and event the frontend calls.
///
/// One constructor serves the app and the bindings test, so the TypeScript the app exports on
/// startup and the committed file the test pins cannot diverge.
pub fn specta_builder() -> tauri_specta::Builder<tauri::Wry> {
    tauri_specta::Builder::<tauri::Wry>::new()
        .events(tauri_specta::collect_events![
            SessionChanged,
            GeneralSettingsChanged,
            LogFilterChanged,
            LogsRecounted,
            X509CertificateChanged,
        ])
        .commands(tauri_specta::collect_commands![
            clear_logs,
            export_logs,
            apply_general_settings,
            reset_general_settings,
            apply_log_filter,
            sign_in,
            sign_out,
            update_state,
        ])
        .typ::<Error>()
}

/// How the TypeScript bindings are rendered.
///
/// No external formatter: the export has to produce the same bytes on every machine that runs
/// it, including one that has no Node toolchain.
pub fn typescript_exporter() -> specta_typescript::Typescript {
    specta_typescript::Typescript::default()
        .bigint(specta_typescript::BigIntExportBehavior::Number)
        .header("/* eslint-disable */\n// @ts-nocheck\n/* tslint:disable */\n")
}

/// Where the committed bindings live.
pub fn bindings_path() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../src-frontend/generated/bindings.ts")
}

/// Rewrites the committed bindings from the current view types.
///
/// The debug build runs this on startup; `cargo run -p firezone-gui-client --example
/// export-bindings` runs it without a display server.
pub fn export_bindings() -> Result<()> {
    export_bindings_to(&bindings_path())
}

/// Exports the bindings to `path`, normalized so the committed file satisfies the repo's
/// hooks: no trailing whitespace, one trailing newline, no formatter involved.
fn export_bindings_to(path: &std::path::Path) -> Result<()> {
    specta_builder()
        .export(typescript_exporter(), path)
        .context("Failed to export TypeScript bindings")?;

    let exported = std::fs::read_to_string(path).context("Failed to read exported bindings")?;
    let mut normalized = exported
        .lines()
        .map(str::trim_end)
        .collect::<Vec<_>>()
        .join("\n");
    normalized.push('\n');
    std::fs::write(path, normalized).context("Failed to write normalized bindings")?;

    Ok(())
}

// Not on Windows: referencing the `tauri::Wry`-typed builder from a test makes the test
// executable import WebView2Loader.dll, which is not beside it, so the process fails to
// load before any test runs.
#[cfg(all(test, not(target_os = "windows")))]
mod tests {
    use super::*;

    /// The debug build re-exports the bindings on startup, so a committed file that differs
    /// from the export dirties the tree of everyone who runs the app.
    #[test]
    fn the_committed_bindings_are_what_the_app_exports() {
        let directory = tempfile::tempdir().unwrap();
        let exported = directory.path().join("bindings.ts");

        export_bindings_to(&exported).unwrap();

        assert_eq!(
            std::fs::read_to_string(exported).unwrap(),
            std::fs::read_to_string(bindings_path()).unwrap(),
            "the committed bindings.ts is stale: run `cargo run -p firezone-gui-client --example export-bindings`"
        );
    }

    #[test]
    fn a_cloud_portal_ignores_the_typed_urls() {
        let form = general_settings_form(Portal::CloudEu, "not a URL", "wss://ignored.example.com");

        let (auth_url, api_url) = form.urls(&AdvancedSettings::default()).unwrap();

        assert_eq!(auth_url.as_str(), "https://eu.app.firezone.dev/");
        assert_eq!(api_url.as_str(), "wss://eu.api.firezone.dev/");
    }

    #[test]
    fn custom_uses_the_typed_urls() {
        let form = general_settings_form(
            Portal::Custom,
            "https://firezone.example.com",
            "wss://api.example.com",
        );

        let (auth_url, api_url) = form.urls(&AdvancedSettings::default()).unwrap();

        assert_eq!(auth_url.as_str(), "https://firezone.example.com/");
        assert_eq!(api_url.as_str(), "wss://api.example.com/");
    }

    #[test]
    fn custom_rejects_an_invalid_url() {
        let form = general_settings_form(Portal::Custom, "not a URL", "wss://api.example.com");

        assert!(form.urls(&AdvancedSettings::default()).is_err());
    }

    #[test]
    fn accepts_a_log_filter_connlib_can_parse() {
        assert!(check_log_filter("info,connlib=debug").is_ok());
    }

    #[test]
    fn rejects_a_log_filter_connlib_cannot_parse() {
        let Error(message) = check_log_filter("info,connlib=nonsense").unwrap_err();

        assert!(message.starts_with("Invalid log filter: "), "{message}");
    }

    #[test]
    fn custom_accepts_local_urls() {
        let form = general_settings_form(
            Portal::Custom,
            "http://localhost:4000",
            "ws://localhost:8081",
        );

        assert!(form.urls(&AdvancedSettings::default()).is_ok());
    }

    #[test]
    fn custom_rejects_a_url_with_the_wrong_scheme() {
        let form = general_settings_form(Portal::Custom, "ftp://x", "wss://api.example.com");

        assert!(form.urls(&AdvancedSettings::default()).is_err());
    }

    #[test]
    fn saving_custom_remembers_the_urls() {
        let form = general_settings_form(
            Portal::Custom,
            "https://firezone.example.com",
            "wss://api.example.com",
        );

        let (general_settings, advanced_settings) = form
            .apply(
                &MdmSettings::default(),
                GeneralSettings::default(),
                AdvancedSettings::default(),
            )
            .unwrap();

        assert_eq!(
            general_settings.custom_auth_url.unwrap().as_str(),
            "https://firezone.example.com/"
        );
        assert_eq!(
            general_settings.custom_api_url.unwrap().as_str(),
            "wss://api.example.com/"
        );
        assert_eq!(
            advanced_settings.auth_url.as_str(),
            "https://firezone.example.com/"
        );
    }

    #[test]
    fn switching_an_existing_custom_configuration_to_cloud_remembers_its_urls() {
        let saved = AdvancedSettings {
            auth_url: Url::parse("https://firezone.example.com").unwrap(),
            api_url: Url::parse("wss://api.example.com").unwrap(),
            ..AdvancedSettings::default()
        };
        let form = general_settings_form(Portal::CloudEu, "", "");

        let (general_settings, advanced_settings) = form
            .apply(&MdmSettings::default(), GeneralSettings::default(), saved)
            .unwrap();

        assert_eq!(
            general_settings.custom_auth_url.unwrap().as_str(),
            "https://firezone.example.com/"
        );
        assert_eq!(
            general_settings.custom_api_url.unwrap().as_str(),
            "wss://api.example.com/"
        );
        assert_eq!(
            advanced_settings.auth_url.as_str(),
            "https://eu.app.firezone.dev/"
        );
    }

    #[test]
    fn saving_a_cloud_portal_keeps_the_remembered_custom_urls() {
        let remembered = GeneralSettings {
            custom_auth_url: Some(Url::parse("https://firezone.example.com").unwrap()),
            custom_api_url: Some(Url::parse("wss://api.example.com").unwrap()),
            ..Default::default()
        };
        let form = general_settings_form(Portal::CloudUs, "", "");

        let (general_settings, advanced_settings) = form
            .apply(
                &MdmSettings::default(),
                remembered,
                AdvancedSettings::default(),
            )
            .unwrap();

        assert_eq!(
            general_settings.custom_auth_url.unwrap().as_str(),
            "https://firezone.example.com/"
        );
        assert_eq!(
            general_settings.custom_api_url.unwrap().as_str(),
            "wss://api.example.com/"
        );
        assert_eq!(
            advanced_settings.auth_url.as_str(),
            "https://app.firezone.dev/"
        );
        assert_eq!(
            advanced_settings.api_url.as_str(),
            "wss://api.firezone.dev/"
        );
    }

    #[test]
    fn a_managed_url_keeps_the_saved_one() {
        let mdm_settings = MdmSettings {
            auth_url: Some(Url::parse("https://managed.example.com").unwrap()),
            ..Default::default()
        };
        let saved = AdvancedSettings {
            auth_url: Url::parse("https://saved.example.com").unwrap(),
            ..AdvancedSettings::default()
        };
        let form = general_settings_form(Portal::CloudEu, "", "");

        let (_, advanced_settings) = form
            .apply(&mdm_settings, GeneralSettings::default(), saved)
            .unwrap();

        assert_eq!(
            advanced_settings.auth_url.as_str(),
            "https://saved.example.com/"
        );
        assert_eq!(
            advanced_settings.api_url.as_str(),
            "wss://eu.api.firezone.dev/"
        );
    }

    fn general_settings_form(portal: Portal, auth_url: &str, api_url: &str) -> GeneralSettingsForm {
        GeneralSettingsForm {
            portal: Some(portal),
            auth_url: Some(auth_url.to_owned()),
            api_url: Some(api_url.to_owned()),
            ..Default::default()
        }
    }
}
