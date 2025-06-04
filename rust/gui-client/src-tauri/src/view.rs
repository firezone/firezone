use std::{path::PathBuf, time::Duration};

use anyhow::Context as _;
use firezone_logging::err_with_src;
use serde::Serialize;
use tauri::{Wry, ipc::Invoke};
use tauri_plugin_dialog::DialogExt as _;

use crate::{
    controller::{ControllerRequest, CtlrTx},
    gui::Managed,
    settings::AdvancedSettings,
};

#[derive(Clone, serde::Deserialize)]
pub struct GeneralSettingsForm {
    pub start_minimized: bool,
    pub start_on_login: bool,
    pub connect_on_start: bool,
    pub account_slug: String,
}

pub fn generate_handler() -> impl Fn(Invoke<Wry>) -> bool + Send + Sync + 'static {
    tauri::generate_handler![
        clear_logs,
        export_logs,
        apply_advanced_settings,
        reset_advanced_settings,
        apply_general_settings,
        reset_general_settings,
        sign_in,
        sign_out,
        update_state,
    ]
}

#[tauri::command]
async fn clear_logs(managed: tauri::State<'_, Managed>) -> Result<()> {
    let (tx, rx) = tokio::sync::oneshot::channel();

    managed
        .ctlr_tx
        .send(ControllerRequest::ClearLogs(tx))
        .await
        .context("Failed to send `ClearLogs` command")?;

    rx.await
        .context("Failed to await `ClearLogs` result")?
        .map_err(anyhow::Error::msg)?;

    Ok(())
}

#[tauri::command]
async fn export_logs(app: tauri::AppHandle, managed: tauri::State<'_, Managed>) -> Result<()> {
    show_export_dialog(&app, managed.ctlr_tx.clone())?;

    Ok(())
}

#[tauri::command]
async fn apply_general_settings(
    managed: tauri::State<'_, Managed>,
    settings: GeneralSettingsForm,
) -> Result<()> {
    if managed.inner().inject_faults {
        tokio::time::sleep(Duration::from_secs(2)).await;
    }

    managed
        .ctlr_tx
        .send(ControllerRequest::ApplyGeneralSettings(Box::new(settings)))
        .await
        .map_err(|e| anyhow::Error::msg(e.to_string()))?;

    Ok(())
}

#[tauri::command]
async fn apply_advanced_settings(
    managed: tauri::State<'_, Managed>,
    settings: AdvancedSettings,
) -> Result<()> {
    if managed.inner().inject_faults {
        tokio::time::sleep(Duration::from_secs(2)).await;
    }

    managed
        .ctlr_tx
        .send(ControllerRequest::ApplyAdvancedSettings(Box::new(settings)))
        .await
        .context("Failed to send `ApplySettings` command")?;

    Ok(())
}

#[tauri::command]
async fn reset_advanced_settings(managed: tauri::State<'_, Managed>) -> Result<()> {
    apply_advanced_settings(managed, AdvancedSettings::default()).await?;

    Ok(())
}

#[tauri::command]
async fn reset_general_settings(managed: tauri::State<'_, Managed>) -> Result<()> {
    managed
        .ctlr_tx
        .send(ControllerRequest::ResetGeneralSettings)
        .await
        .map_err(|e| anyhow::Error::msg(e.to_string()))?;

    Ok(())
}

/// Pops up the "Save File" dialog
fn show_export_dialog(app: &tauri::AppHandle, ctlr_tx: CtlrTx) -> Result<()> {
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
            if let Err(e) = ctlr_tx.blocking_send(ControllerRequest::ExportLogs { path, stem }) {
                tracing::warn!("Failed to send `ExportLogs` command: {e}");
            }
        });
    Ok(())
}

#[tauri::command]
async fn sign_in(managed: tauri::State<'_, Managed>) -> Result<()> {
    managed
        .ctlr_tx
        .send(ControllerRequest::SignIn)
        .await
        .context("Failed to send `SignIn` command")?;

    Ok(())
}

#[tauri::command]
async fn sign_out(managed: tauri::State<'_, Managed>) -> Result<()> {
    managed
        .ctlr_tx
        .send(ControllerRequest::SignOut)
        .await
        .context("Failed to send `SignOut` command")?;

    Ok(())
}

#[tauri::command]
async fn update_state(managed: tauri::State<'_, Managed>) -> Result<()> {
    managed
        .ctlr_tx
        .send(ControllerRequest::UpdateState)
        .await
        .context("Failed to send `UpdateState` command")?;

    Ok(())
}

type Result<T> = std::result::Result<T, Error>;

#[derive(Debug)]
struct Error(anyhow::Error);

impl Serialize for Error {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&format!("{:#}", self.0))
    }
}

impl From<anyhow::Error> for Error {
    fn from(value: anyhow::Error) -> Self {
        Self(value)
    }
}

impl From<String> for Error {
    fn from(value: String) -> Self {
        Self(anyhow::Error::msg(value))
    }
}
