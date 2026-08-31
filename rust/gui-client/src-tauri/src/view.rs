use std::{path::PathBuf, time::Duration};

use anyhow::Context as _;
use logging::err_with_src;
use serde::Serialize;
use tauri_plugin_dialog::DialogExt as _;

use crate::{
    controller::ControllerRequest,
    gui::Managed,
    logging::FileCount,
    settings::{AdvancedSettings, AdvancedSettingsViewModel, GeneralSettingsViewModel},
};

#[derive(Clone, serde::Deserialize, specta::Type)]
pub struct GeneralSettingsForm {
    pub start_minimized: bool,
    pub start_on_login: bool,
    pub connect_on_start: bool,
    pub account_slug: String,
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
pub struct AdvancedSettingsChanged(pub AdvancedSettingsViewModel);

#[derive(Clone, serde::Serialize, specta::Type, tauri_specta::Event)]
pub struct LogsRecounted(pub FileCount);

/// The platform keystore's certificate as the X.509 page renders it.
#[derive(Clone, serde::Serialize, specta::Type, tauri_specta::Event)]
pub struct X509CertificateChanged(pub X509Certificate);

/// What the Tunnel service last loaded from the platform keystore.
#[derive(Clone, serde::Serialize, specta::Type)]
pub enum X509Certificate {
    /// The keystore holds this certificate, described by the parser's rows.
    Loaded {
        identity: X509Identity,
        fields: Vec<X509DetailField>,
    },
    /// The keystore holds no client certificate.
    Absent,
    /// The keystore could not hand out a client identity.
    Error(X509Error),
}

/// Mirrors [`x509_keystore::ClientIdentity`], which decides what the sign-in control says.
#[derive(Clone, serde::Serialize, specta::Type)]
pub enum X509Identity {
    Absent,
    Claimed { email: Option<String> },
}

/// Mirrors [`x509_keystore::Error`] so the frontend writes the sentence it shows.
#[derive(Clone, serde::Serialize, specta::Type)]
pub enum X509Error {
    UnreadableStore { store: String, error: String },
    MissingP11Kit,
    UnreadablePkcs11Keystore { modules: Vec<String> },
    NoUsableIdentity { causes: Vec<X509UnusableCause> },
    IdentityUnavailable { message: String },
    UnreadableKeystore { message: String },
}

/// Mirrors [`x509_keystore::UnusableCause`].
#[derive(Clone, serde::Serialize, specta::Type)]
pub enum X509UnusableCause {
    UnsupportedKeyAlgorithm,
    KeyRefused { error: String },
    KeyMissing,
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
    NotAnEmailAddress,
    NotAUuid,
    Ambiguous,
    PlaceholderIdentifier,
    UnknownAttribute,
    NotYetValid,
    Expired,
    MissingClientAuthEku,
    DigitalSignatureNotAllowed,
}

impl From<&std::result::Result<Option<x509_keystore::ParsedCertificate>, x509_keystore::Error>>
    for X509Certificate
{
    fn from(
        x509: &std::result::Result<Option<x509_keystore::ParsedCertificate>, x509_keystore::Error>,
    ) -> Self {
        match x509 {
            Ok(Some(certificate)) => Self::Loaded {
                identity: X509Identity::from(&certificate.identity()),
                fields: certificate
                    .detail_fields()
                    .into_iter()
                    .map(X509DetailField::from)
                    .collect(),
            },
            Ok(None) => Self::Absent,
            Err(error) => Self::Error(X509Error::from(error)),
        }
    }
}

impl From<&x509_keystore::ClientIdentity> for X509Identity {
    fn from(identity: &x509_keystore::ClientIdentity) -> Self {
        match identity {
            x509_keystore::ClientIdentity::Absent => Self::Absent,
            x509_keystore::ClientIdentity::Claimed { email } => Self::Claimed {
                email: email.clone(),
            },
        }
    }
}

impl From<&x509_keystore::Error> for X509Error {
    fn from(error: &x509_keystore::Error) -> Self {
        match error {
            x509_keystore::Error::UnreadableStore { store, error } => Self::UnreadableStore {
                store: store.clone(),
                error: error.clone(),
            },
            x509_keystore::Error::MissingP11Kit => Self::MissingP11Kit,
            x509_keystore::Error::UnreadablePkcs11Keystore { modules } => {
                Self::UnreadablePkcs11Keystore {
                    modules: modules.clone(),
                }
            }
            x509_keystore::Error::NoUsableIdentity { causes } => Self::NoUsableIdentity {
                causes: causes
                    .iter()
                    .cloned()
                    .map(X509UnusableCause::from)
                    .collect(),
            },
            x509_keystore::Error::IdentityUnavailable { message } => Self::IdentityUnavailable {
                message: message.clone(),
            },
            x509_keystore::Error::UnreadableKeystore { message } => Self::UnreadableKeystore {
                message: message.clone(),
            },
        }
    }
}

impl From<x509_keystore::UnusableCause> for X509UnusableCause {
    fn from(cause: x509_keystore::UnusableCause) -> Self {
        match cause {
            x509_keystore::UnusableCause::UnsupportedKeyAlgorithm => Self::UnsupportedKeyAlgorithm,
            x509_keystore::UnusableCause::KeyRefused { error } => Self::KeyRefused { error },
            x509_keystore::UnusableCause::KeyMissing => Self::KeyMissing,
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
            x509_keystore::ValidationError::NotAnEmailAddress => Self::NotAnEmailAddress,
            x509_keystore::ValidationError::NotAUuid => Self::NotAUuid,
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
pub async fn clear_logs(managed: tauri::State<'_, Managed>) -> Result<()> {
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
pub async fn export_logs(app: tauri::AppHandle, managed: tauri::State<'_, Managed>) -> Result<()> {
    show_export_dialog(&app, managed.inner().clone())?;

    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn apply_general_settings(
    managed: tauri::State<'_, Managed>,
    settings: GeneralSettingsForm,
) -> Result<()> {
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
pub async fn apply_advanced_settings(
    managed: tauri::State<'_, Managed>,
    settings: AdvancedSettings,
) -> Result<()> {
    if managed.inner().inject_faults {
        tokio::time::sleep(Duration::from_secs(2)).await;
    }

    managed
        .send_request(ControllerRequest::ApplyAdvancedSettings(Box::new(settings)))
        .await?;

    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn reset_advanced_settings(managed: tauri::State<'_, Managed>) -> Result<()> {
    apply_advanced_settings(managed, AdvancedSettings::default()).await?;

    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn reset_general_settings(managed: tauri::State<'_, Managed>) -> Result<()> {
    managed
        .send_request(ControllerRequest::ResetGeneralSettings)
        .await?;

    Ok(())
}

/// Pops up the "Save File" dialog
fn show_export_dialog(app: &tauri::AppHandle, managed: Managed) -> Result<()> {
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
pub async fn sign_in(managed: tauri::State<'_, Managed>) -> Result<()> {
    managed.send_request(ControllerRequest::SignIn).await?;

    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn sign_out(managed: tauri::State<'_, Managed>) -> Result<()> {
    managed.send_request(ControllerRequest::SignOut).await?;

    Ok(())
}

#[tauri::command]
#[specta::specta]
pub async fn update_state(managed: tauri::State<'_, Managed>) -> Result<()> {
    managed.send_request(ControllerRequest::UpdateState).await?;

    Ok(())
}

type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, specta::Type, Serialize)]
pub struct Error(String);

impl From<anyhow::Error> for Error {
    fn from(error: anyhow::Error) -> Self {
        Self(format!("{error:#}"))
    }
}
