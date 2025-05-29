use std::{path::PathBuf, time::Duration};

use anyhow::{Context as _, Result, bail};
use firezone_logging::err_with_src;
use tauri::{Wry, ipc::Invoke};
use tauri_plugin_dialog::DialogExt as _;

use crate::{
    controller::{ControllerRequest, CtlrTx},
    gui::Managed,
    settings::AdvancedSettings,
};

pub fn generate_handler() -> impl Fn(Invoke<Wry>) -> bool + Send + Sync + 'static {
    tauri::generate_handler![
        get_git_version,
        clear_logs,
        export_logs,
        apply_advanced_settings,
        reset_advanced_settings,
        sign_in,
        sign_out,
        update_state,
    ]
}

#[tauri::command]
fn get_git_version() -> String {
    option_env!("GITHUB_SHA").unwrap_or("unknown").to_owned()
}

#[tauri::command]
async fn clear_logs(managed: tauri::State<'_, Managed>) -> Result<(), String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    if let Err(error) = managed.ctlr_tx.send(ControllerRequest::ClearLogs(tx)).await {
        // Tauri will only log errors to the JS console for us, so log this ourselves.
        tracing::error!(
            "Error while asking `Controller` to clear logs: {}",
            err_with_src(&error)
        );
        return Err(error.to_string());
    }
    if let Err(error) = rx.await {
        tracing::error!(
            "Error while awaiting log-clearing operation: {}",
            err_with_src(&error)
        );
        return Err(error.to_string());
    }
    Ok(())
}

#[tauri::command]
async fn export_logs(
    app: tauri::AppHandle,
    managed: tauri::State<'_, Managed>,
) -> Result<(), String> {
    show_export_dialog(&app, managed.ctlr_tx.clone()).map_err(|e| e.to_string())
}

#[tauri::command]
async fn apply_advanced_settings(
    managed: tauri::State<'_, Managed>,
    settings: AdvancedSettings,
) -> Result<(), String> {
    if managed.inner().inject_faults {
        tokio::time::sleep(Duration::from_secs(2)).await;
    }

    managed
        .ctlr_tx
        .send(ControllerRequest::ApplySettings(Box::new(settings)))
        .await
        .map_err(|e| e.to_string())?;

    Ok(())
}

#[tauri::command]
async fn reset_advanced_settings(managed: tauri::State<'_, Managed>) -> Result<(), String> {
    apply_advanced_settings(managed, AdvancedSettings::default()).await?;

    Ok(())
}

/// Pops up the "Save File" dialog
fn show_export_dialog(app: &tauri::AppHandle, ctlr_tx: CtlrTx) -> Result<()> {
    let now = chrono::Local::now();
    let datetime_string = now.format("%Y_%m_%d-%H-%M");
    let stem = PathBuf::from(format!("firezone_logs_{datetime_string}"));
    let filename = stem.with_extension("zip");
    let Some(filename) = filename.to_str() else {
        bail!("zip filename isn't valid Unicode");
    };

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
async fn sign_in(managed: tauri::State<'_, Managed>) -> Result<(), String> {
    managed
        .ctlr_tx
        .send(ControllerRequest::SignIn)
        .await
        .context("Failed to send `SignIn` command")
        .map_err(|e| e.to_string())?;

    Ok(())
}

#[tauri::command]
async fn sign_out(managed: tauri::State<'_, Managed>) -> Result<(), String> {
    managed
        .ctlr_tx
        .send(ControllerRequest::SignOut)
        .await
        .context("Failed to send `SignOut` command")
        .map_err(|e| e.to_string())?;

    Ok(())
}

#[tauri::command]
async fn update_state(managed: tauri::State<'_, Managed>) -> Result<(), String> {
    managed
        .ctlr_tx
        .send(ControllerRequest::UpdateState)
        .await
        .context("Failed to send `UpdateState` command")
        .map_err(|e| e.to_string())?;

    Ok(())
}
