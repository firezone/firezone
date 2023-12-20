//! Everything for logging to files, zipping up the files for export, and counting the files

use crate::client::gui::{ControllerRequest, CtlrTx, Managed};
use anyhow::Result;
use connlib_client_shared::file_logger;
use serde::Serialize;
use std::{
    path::{Path, PathBuf},
    result::Result as StdResult,
    str::FromStr,
    time::Duration,
};
use tauri::Manager;
use tokio::fs;
use tracing::subscriber::set_global_default;
use tracing_log::LogTracer;
use tracing_subscriber::{fmt, layer::SubscriberExt, reload, EnvFilter, Layer, Registry};

pub(crate) struct Handles {
    pub logger: file_logger::Handle,
    pub _reloader: reload::Handle<EnvFilter, Registry>,
}

/// Set up logs for the first time.
/// Must be called inside Tauri's `setup` callback, after the app has changed directory
pub(crate) fn setup(log_filter: &str) -> Result<Handles> {
    let (layer, logger) = file_logger::layer(Path::new("logs"));
    let filter = EnvFilter::from_str(log_filter)?;
    let (filter, reloader) = reload::Layer::new(filter);
    let subscriber = Registry::default()
        .with(layer.with_filter(filter))
        .with(fmt::layer().with_filter(EnvFilter::from_str(log_filter)?));
    set_global_default(subscriber)?;
    LogTracer::init()?;
    Ok(Handles {
        logger,
        _reloader: reloader,
    })
}

#[tauri::command]
pub(crate) async fn start_stop_log_counting(
    managed: tauri::State<'_, Managed>,
    enable: bool,
) -> StdResult<(), String> {
    managed
        .ctlr_tx
        .send(ControllerRequest::StartStopLogCounting(enable))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub(crate) async fn clear_logs() -> StdResult<(), String> {
    clear_logs_inner().await.map_err(|e| e.to_string())
}

#[tauri::command]
pub(crate) async fn export_logs(managed: tauri::State<'_, Managed>) -> StdResult<(), String> {
    export_logs_inner(managed.ctlr_tx.clone())
        .await
        .map_err(|e| e.to_string())
}

pub(crate) async fn clear_logs_inner() -> Result<()> {
    todo!()
}

/// Pops up the "Save File" dialog
pub(crate) async fn export_logs_inner(ctlr_tx: CtlrTx) -> Result<()> {
    tauri::api::dialog::FileDialogBuilder::new()
        .add_filter("Zip", &["zip"])
        .save_file(move |file_path| match file_path {
            None => {}
            Some(x) => {
                // blocking_send here because we're in a sync callback within Tauri somewhere
                ctlr_tx
                    .blocking_send(ControllerRequest::ExportLogs(x))
                    .unwrap()
            }
        });
    Ok(())
}

/// Exports logs to a zip file
pub(crate) async fn export_logs_to(file_path: PathBuf) -> Result<()> {
    tracing::trace!("Exporting logs to {file_path:?}");

    let mut entries = fs::read_dir("logs").await?;
    while let Some(entry) = entries.next_entry().await? {
        let path = entry.path();
        tracing::trace!("Export {path:?}");
    }
    tokio::time::sleep(Duration::from_secs(1)).await;
    // TODO: Somehow signal back to the GUI to unlock the log buttons when the export completes, or errors out
    Ok(())
}

#[derive(Clone, Serialize)]
struct FileCount {
    files: u64,
    bytes: u64,
}

pub(crate) async fn count_logs(app: tauri::AppHandle) -> Result<()> {
    let mut dir = fs::read_dir("logs").await?;
    let mut files: u64 = 0;
    let mut bytes: u64 = 0;
    while let Some(entry) = dir.next_entry().await? {
        // TODO: Remove sleep before merging
        // This is useful for debugging to show how the GUI thinks and make sure nothing else blocks on this
        tokio::time::sleep(Duration::from_millis(200)).await;
        let md = entry.metadata().await?;
        files += 1;
        bytes += md.len();
        app.emit_all("file_count_progress", FileCount { files, bytes })?;
    }
    Ok(())
}
