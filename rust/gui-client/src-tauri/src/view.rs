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

/// The keystore diagnostics as the settings page renders them.
#[derive(Clone, serde::Serialize, specta::Type, tauri_specta::Event)]
pub struct X509StatusChanged(pub X509Status);

#[derive(Clone, serde::Serialize, specta::Type)]
pub struct X509Status {
    pub problems: Vec<X509Problem>,
    pub sections: Vec<X509DetailSection>,
    pub identity: X509Identity,
}

/// Mirrors [`x509_keystore::ClientIdentity`], which decides what the sign-in control says.
#[derive(Clone, serde::Serialize, specta::Type)]
pub enum X509Identity {
    Absent,
    Claimed { email: Option<String> },
}

/// Mirrors [`x509_keystore::Problem`] so the frontend writes the sentence it shows.
#[derive(Clone, serde::Serialize, specta::Type)]
pub enum X509Problem {
    NoWindowsCertificate {
        subject_cn: String,
    },
    NoUsableWindowsCertificate {
        certificates: Vec<X509UnusableCertificate>,
    },
    UnreadableWindowsStores {
        stores: Vec<X509UnreadableStore>,
    },
    NoPkcs11Certificate {
        subject_cn: String,
    },
    NoUsablePkcs11Certificate {
        certificates: Vec<X509UnusableCertificate>,
    },
    UnreadablePkcs11Keystore,
    UnreadableKeystore,
    MissingPackage {
        package: X509Package,
    },
    UnsupportedPlatform,
}

/// Mirrors [`x509_keystore::Package`].
#[derive(Clone, serde::Serialize, specta::Type)]
pub enum X509Package {
    P11Kit,
}

/// Mirrors [`x509_keystore::UnusableCertificate`].
#[derive(Clone, serde::Serialize, specta::Type)]
pub struct X509UnusableCertificate {
    pub fingerprint: String,
    pub cause: X509UnusableCause,
}

/// Mirrors [`x509_keystore::UnusableCause`].
#[derive(Clone, serde::Serialize, specta::Type)]
pub enum X509UnusableCause {
    UnsupportedKeyAlgorithm,
    WindowsKeyRefused { error: String },
    WindowsKeyMissing,
    Pkcs11KeyMissing,
}

/// Mirrors [`x509_keystore::UnreadableStore`].
#[derive(Clone, serde::Serialize, specta::Type)]
pub struct X509UnreadableStore {
    pub store: String,
    pub error: String,
}

#[derive(Clone, serde::Serialize, specta::Type)]
pub struct X509DetailSection {
    pub title: String,
    pub fields: Vec<X509DetailField>,
}

#[derive(Clone, serde::Serialize, specta::Type)]
pub struct X509DetailField {
    pub label: String,
    pub value: X509FieldValue,
    pub problem: Option<X509FieldProblem>,
}

/// Mirrors [`x509_keystore::FieldValue`].
#[derive(Clone, serde::Serialize, specta::Type)]
pub enum X509FieldValue {
    Present(String),
    Absent,
}

/// Mirrors [`x509_keystore::FieldProblem`] so the frontend writes the sentence it shows.
#[derive(Clone, serde::Serialize, specta::Type)]
pub enum X509FieldProblem {
    Rejected(X509RejectionReason),
    Unreadable(String),
}

/// Mirrors [`x509_keystore::RejectionReason`].
#[derive(Clone, serde::Serialize, specta::Type)]
pub enum X509RejectionReason {
    Empty,
    TooLong,
    NotAnEmailAddress,
    NotAUuid,
    Ambiguous,
    PlaceholderIdentifier,
    UnknownAttribute,
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

impl From<&x509_keystore::Status> for X509Status {
    fn from(status: &x509_keystore::Status) -> Self {
        Self {
            identity: X509Identity::from(&status.identity),
            problems: status
                .problems
                .iter()
                .cloned()
                .map(X509Problem::from)
                .collect(),
            sections: status
                .sections
                .iter()
                .map(|section| X509DetailSection {
                    title: section.title.clone(),
                    fields: section
                        .fields
                        .iter()
                        .map(|field| X509DetailField {
                            label: field.label.clone(),
                            value: field.value.clone().into(),
                            problem: field.problem.clone().map(X509FieldProblem::from),
                        })
                        .collect(),
                })
                .collect(),
        }
    }
}

impl From<x509_keystore::Problem> for X509Problem {
    fn from(problem: x509_keystore::Problem) -> Self {
        match problem {
            x509_keystore::Problem::NoWindowsCertificate { subject_cn } => {
                Self::NoWindowsCertificate { subject_cn }
            }
            x509_keystore::Problem::NoUsableWindowsCertificate { certificates } => {
                Self::NoUsableWindowsCertificate {
                    certificates: certificates.into_iter().map(Into::into).collect(),
                }
            }
            x509_keystore::Problem::UnreadableWindowsStores { stores } => {
                Self::UnreadableWindowsStores {
                    stores: stores.into_iter().map(Into::into).collect(),
                }
            }
            x509_keystore::Problem::NoPkcs11Certificate { subject_cn } => {
                Self::NoPkcs11Certificate { subject_cn }
            }
            x509_keystore::Problem::NoUsablePkcs11Certificate { certificates } => {
                Self::NoUsablePkcs11Certificate {
                    certificates: certificates.into_iter().map(Into::into).collect(),
                }
            }
            x509_keystore::Problem::UnreadablePkcs11Keystore => Self::UnreadablePkcs11Keystore,
            x509_keystore::Problem::UnreadableKeystore => Self::UnreadableKeystore,
            x509_keystore::Problem::MissingPackage { package } => Self::MissingPackage {
                package: package.into(),
            },
            x509_keystore::Problem::UnsupportedPlatform => Self::UnsupportedPlatform,
        }
    }
}

impl From<x509_keystore::Package> for X509Package {
    fn from(package: x509_keystore::Package) -> Self {
        match package {
            x509_keystore::Package::P11Kit => Self::P11Kit,
        }
    }
}

impl From<x509_keystore::UnusableCertificate> for X509UnusableCertificate {
    fn from(certificate: x509_keystore::UnusableCertificate) -> Self {
        Self {
            fingerprint: certificate.fingerprint,
            cause: certificate.cause.into(),
        }
    }
}

impl From<x509_keystore::UnusableCause> for X509UnusableCause {
    fn from(cause: x509_keystore::UnusableCause) -> Self {
        match cause {
            x509_keystore::UnusableCause::UnsupportedKeyAlgorithm => Self::UnsupportedKeyAlgorithm,
            x509_keystore::UnusableCause::WindowsKeyRefused { error } => {
                Self::WindowsKeyRefused { error }
            }
            x509_keystore::UnusableCause::WindowsKeyMissing => Self::WindowsKeyMissing,
            x509_keystore::UnusableCause::Pkcs11KeyMissing => Self::Pkcs11KeyMissing,
        }
    }
}

impl From<x509_keystore::UnreadableStore> for X509UnreadableStore {
    fn from(store: x509_keystore::UnreadableStore) -> Self {
        Self {
            store: store.store,
            error: store.error,
        }
    }
}

impl From<x509_keystore::FieldValue> for X509FieldValue {
    fn from(value: x509_keystore::FieldValue) -> Self {
        match value {
            x509_keystore::FieldValue::Present(value) => Self::Present(value),
            x509_keystore::FieldValue::Absent => Self::Absent,
        }
    }
}

impl From<x509_keystore::FieldProblem> for X509FieldProblem {
    fn from(problem: x509_keystore::FieldProblem) -> Self {
        match problem {
            x509_keystore::FieldProblem::Rejected(reason) => Self::Rejected(reason.into()),
            x509_keystore::FieldProblem::Unreadable(message) => Self::Unreadable(message),
        }
    }
}

impl From<x509_keystore::RejectionReason> for X509RejectionReason {
    fn from(reason: x509_keystore::RejectionReason) -> Self {
        match reason {
            x509_keystore::RejectionReason::Empty => Self::Empty,
            x509_keystore::RejectionReason::TooLong => Self::TooLong,
            x509_keystore::RejectionReason::NotAnEmailAddress => Self::NotAnEmailAddress,
            x509_keystore::RejectionReason::NotAUuid => Self::NotAUuid,
            x509_keystore::RejectionReason::Ambiguous => Self::Ambiguous,
            x509_keystore::RejectionReason::PlaceholderIdentifier => Self::PlaceholderIdentifier,
            x509_keystore::RejectionReason::UnknownAttribute => Self::UnknownAttribute,
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
