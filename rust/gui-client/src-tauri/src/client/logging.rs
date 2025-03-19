use crate::client::gui::Managed;
use anyhow::{Result, bail};
use firezone_gui_client_common::{
    controller::{ControllerRequest, CtlrTx},
    logging as common,
};
use firezone_logging::err_with_src;
use std::path::PathBuf;
use tauri_plugin_dialog::DialogExt as _;

#[tauri::command]
pub(crate) async fn clear_logs(managed: tauri::State<'_, Managed>) -> Result<(), String> {
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
pub(crate) async fn export_logs(
    app: tauri::AppHandle,
    managed: tauri::State<'_, Managed>,
) -> Result<(), String> {
    show_export_dialog(&app, managed.ctlr_tx.clone()).map_err(|e| e.to_string())
}

#[tauri::command]
pub(crate) async fn count_logs() -> Result<common::FileCount, String> {
    common::count_logs().await.map_err(|e| e.to_string())
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
