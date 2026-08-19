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
#[derive(Clone, serde::Serialize, specta::Type)]
pub struct X509Status {
    pub summary: String,
    pub sections: Vec<X509DetailSection>,
}

#[derive(Clone, serde::Serialize, specta::Type)]
pub struct X509DetailSection {
    pub title: String,
    pub fields: Vec<X509DetailField>,
}

#[derive(Clone, serde::Serialize, specta::Type)]
pub struct X509DetailField {
    pub label: String,
    pub value: String,
}

impl From<x509_keystore::Status> for X509Status {
    fn from(status: x509_keystore::Status) -> Self {
        Self {
            summary: status.summary,
            sections: status
                .sections
                .into_iter()
                .map(|section| X509DetailSection {
                    title: section.title,
                    fields: section
                        .fields
                        .into_iter()
                        .map(|field| X509DetailField {
                            label: field.label,
                            value: field.value,
                        })
                        .collect(),
                })
                .collect(),
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
pub async fn x509_status(managed: tauri::State<'_, Managed>) -> Result<X509Status> {
    let (tx, rx) = tokio::sync::oneshot::channel();

    managed
        .send_request(ControllerRequest::GetX509Status(tx))
        .await?;

    let status = rx
        .await
        .context("Failed to await `GetX509Status` result")?
        .map_err(anyhow::Error::msg)?;

    Ok(status.into())
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
