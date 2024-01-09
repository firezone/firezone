//! Everything for logging to files, zipping up the files for export, and counting the files

use crate::client::gui::{ControllerRequest, CtlrTx, Managed};
use anyhow::{bail, Result};
use connlib_client_shared::file_logger;
use serde::Serialize;
use std::{
    fs, io,
    path::{Path, PathBuf},
    result::Result as StdResult,
    str::FromStr,
};
use tauri::Manager;
use tokio::task::spawn_blocking;
use tracing::subscriber::set_global_default;
use tracing_log::LogTracer;
use tracing_subscriber::{fmt, layer::SubscriberExt, reload, EnvFilter, Layer, Registry};

/// If you don't store `Handles` in a variable, the file logger handle will drop immediately,
/// resulting in empty log files.
#[must_use]
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
    // Delegate this to Controller so that it can decide whether to obey.
    // e.g. if there's already a count task running, it may refuse to start another.
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
    let now = chrono::Local::now();
    let datetime_string = now.format("%Y_%m_%d-%H-%M");
    let stem = PathBuf::from(format!("connlib-{datetime_string}"));
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

/// Exports logs to a zip file
///
/// # Arguments
///
/// * `path` - Where the zip archive will be written
/// * `stem` - A directory containing all the log files inside the zip archive, to avoid creating a ["tar bomb"](https://www.linfo.org/tarbomb.html). This comes from the automatically-generated name of the archive, even if the user changes it to e.g. `logs.zip`
pub(crate) async fn export_logs_to(path: PathBuf, stem: PathBuf) -> Result<()> {
    tracing::trace!("Exporting logs to {path:?}");

    // TODO: Consider https://github.com/Majored/rs-async-zip/issues instead of `spawn_blocking`
    spawn_blocking(move || {
        let f = fs::File::create(path)?;
        let mut zip = zip::ZipWriter::new(f);
        // All files will have the same modified time. Doing otherwise seems to be difficult
        let options = zip::write::FileOptions::default();
        for entry in fs::read_dir("logs")? {
            let entry = entry?;
            let Some(path) = stem.join(entry.file_name()).to_str().map(|x| x.to_owned()) else {
                bail!("log filename isn't valid Unicode")
            };
            zip.start_file(path, options)?;
            let mut f = fs::File::open(entry.path())?;
            io::copy(&mut f, &mut zip)?;
        }
        zip.finish()?;
        Ok::<_, anyhow::Error>(())
    })
    .await??;

    // TODO: Somehow signal back to the GUI to unlock the log buttons when the export completes, or errors out
    Ok(())
}

#[derive(Clone, Default, Serialize)]
struct FileCount {
    bytes: u64,
    files: u64,
}

pub(crate) async fn count_logs(app: tauri::AppHandle) -> Result<()> {
    let mut dir = tokio::fs::read_dir("logs").await?;
    let mut file_count = FileCount::default();
    // Zero out the GUI
    app.emit_all("file_count_progress", None::<FileCount>)?;
    while let Some(entry) = dir.next_entry().await? {
        let md = entry.metadata().await?;
        file_count.files += 1;
        file_count.bytes += md.len();
    }
    // Show the result on the GUI
    app.emit_all("file_count_progress", Some(&file_count))?;
    Ok(())
}
