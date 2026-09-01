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
    /// What is wrong with the value, [`None`] when nothing is.
    pub problem: Option<X509FieldProblem>,
}

/// What is wrong with a row: a value the parser flagged, or the keystore's private key.
#[derive(Clone, serde::Serialize, specta::Type)]
pub enum X509FieldProblem {
    Invalid(X509ValidationError),
    Unusable(X509UnusableCause),
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

impl From<&std::result::Result<Option<x509_keystore::ReportedCertificate>, x509_keystore::Error>>
    for X509Certificate
{
    fn from(
        x509: &std::result::Result<
            Option<x509_keystore::ReportedCertificate>,
            x509_keystore::Error,
        >,
    ) -> Self {
        match x509 {
            Ok(Some(report)) => Self::Loaded {
                // An identity is only claimed by a certificate we can present: an unusable
                // one authenticates nothing, so the sign-in control must not offer it.
                identity: if report.presentable() {
                    X509Identity::from(&report.certificate.identity())
                } else {
                    X509Identity::Absent
                },
                fields: detail_fields(report),
            },
            Ok(None) => Self::Absent,
            Err(error) => Self::Error(X509Error::from(error)),
        }
    }
}

/// The X.509 page's rows: the parser's, led by the private-key row where the keystore
/// cannot sign with the certificate.
fn detail_fields(report: &x509_keystore::ReportedCertificate) -> Vec<X509DetailField> {
    let unusable = report.unusable.clone().map(|cause| X509DetailField {
        // No X.509 attribute says whether we hold a key we can sign with, so the row names
        // what the keystore looked for.
        label: "Private Key".to_owned(),
        value: None,
        problem: Some(X509FieldProblem::Unusable(X509UnusableCause::from(cause))),
    });

    unusable
        .into_iter()
        .chain(
            report
                .certificate
                .detail_fields()
                .into_iter()
                .map(X509DetailField::from),
        )
        .collect()
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
            problem: field
                .problem
                .map(|error| X509FieldProblem::Invalid(X509ValidationError::from(error))),
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

/// The tauri-specta registry of every command and event the frontend calls.
///
/// One constructor serves the app and the bindings test, so the TypeScript the app exports on
/// startup and the committed file the test pins cannot diverge.
pub fn specta_builder() -> tauri_specta::Builder<tauri::Wry> {
    tauri_specta::Builder::<tauri::Wry>::new()
        .events(tauri_specta::collect_events![
            SessionChanged,
            GeneralSettingsChanged,
            AdvancedSettingsChanged,
            LogsRecounted,
            X509CertificateChanged,
        ])
        .commands(tauri_specta::collect_commands![
            clear_logs,
            export_logs,
            apply_advanced_settings,
            reset_advanced_settings,
            apply_general_settings,
            reset_general_settings,
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
pub fn export_bindings() -> anyhow::Result<()> {
    export_bindings_to(&bindings_path())
}

/// Exports the bindings to `path`, normalized so the committed file satisfies the repo's
/// hooks: no trailing whitespace, one trailing newline, no formatter involved.
fn export_bindings_to(path: &std::path::Path) -> anyhow::Result<()> {
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
}
