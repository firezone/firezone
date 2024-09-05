use crate::client::gui::{ControllerRequest, CtlrTx, Managed};
use anyhow::{bail, Result};
use firezone_gui_client_common::logging as common;
use std::path::PathBuf;

#[tauri::command]
pub(crate) async fn clear_logs(managed: tauri::State<'_, Managed>) -> Result<(), String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    if let Err(error) = managed.ctlr_tx.send(ControllerRequest::ClearLogs(tx)).await {
        // Tauri will only log errors to the JS console for us, so log this ourselves.
        tracing::error!(?error, "Error while asking `Controller` to clear logs");
        return Err(error.to_string());
    }
    if let Err(error) = rx.await {
        tracing::error!(?error, "Error while awaiting log-clearing operation");
        return Err(error.to_string());
    }
    Ok(())
}

#[tauri::command]
pub(crate) async fn export_logs(managed: tauri::State<'_, Managed>) -> Result<(), String> {
    show_export_dialog(managed.ctlr_tx.clone()).map_err(|e| e.to_string())
}

#[tauri::command]
pub(crate) async fn count_logs() -> Result<common::FileCount, String> {
    common::count_logs().await.map_err(|e| e.to_string())
}

/// Pops up the "Save File" dialog
fn show_export_dialog(ctlr_tx: CtlrTx) -> Result<()> {
    let now = chrono::Local::now();
    let datetime_string = now.format("%Y_%m_%d-%H-%M");
    let stem = PathBuf::from(format!("firezone_logs_{datetime_string}"));
    let filename = stem.with_extension("zip");
    let Some(filename) = filename.to_str() else {
        bail!("zip filename isn't valid Unicode");
    };

    tauri::api::dialog::FileDialogBuilder::new()
        .add_filter("Zip", &["zip"])
        .set_file_name(filename)
        .save_file(move |file_path| match file_path {
            None => {}
            Some(path) => {
                // blocking_send here because we're in a sync callback within Tauri somewhere
                ctlr_tx
                    .blocking_send(ControllerRequest::ExportLogs { path, stem })
                    .unwrap()
            }
        });
    Ok(())
}
