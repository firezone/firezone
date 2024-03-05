//! Everything for logging to files, zipping up the files for export, and counting the files

use crate::client::{
    gui::{ControllerRequest, CtlrTx, Managed},
    known_dirs,
};
use anyhow::{bail, Context, Result};
use connlib_client_shared::file_logger;
use serde::Serialize;
use std::{fs, io, path::PathBuf, result::Result as StdResult, str::FromStr};
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

#[derive(Debug, thiserror::Error)]
pub(crate) enum Error {
    #[error("Couldn't compute our local AppData path")]
    CantFindLocalAppDataFolder,
    #[error("Couldn't create logs dir: {0}")]
    CreateDirAll(std::io::Error),
    #[error("Log filter couldn't be parsed")]
    Parse(#[from] tracing_subscriber::filter::ParseError),
    #[error(transparent)]
    SetGlobalDefault(#[from] tracing::subscriber::SetGlobalDefaultError),
    #[error(transparent)]
    SetLogger(#[from] tracing_log::log_tracer::SetLoggerError),
}

/// Set up logs after the process has started
pub(crate) fn setup(log_filter: &str) -> Result<Handles, Error> {
    let log_path = log_path()?;
    tracing::debug!(?log_path, "Log path");

    std::fs::create_dir_all(&log_path).map_err(Error::CreateDirAll)?;
    let (layer, logger) = file_logger::layer(&log_path);
    let filter = EnvFilter::from_str(log_filter)?;
    let (filter, reloader) = reload::Layer::new(filter);
    let subscriber = Registry::default()
        .with(layer.with_filter(filter))
        .with(fmt::layer().with_filter(EnvFilter::from_str(log_filter)?));
    set_global_default(subscriber)?;
    if let Err(error) = output_vt100::try_init() {
        tracing::warn!(
            ?error,
            "Failed to init vt100 terminal colors (expected in release builds and in CI)"
        );
    }
    LogTracer::init()?;
    Ok(Handles {
        logger,
        _reloader: reloader,
    })
}

/// Sets up logging for stderr only, with INFO level by default
pub(crate) fn debug_command_setup() -> Result<(), Error> {
    let filter = EnvFilter::builder()
        .with_default_directive(tracing_subscriber::filter::LevelFilter::INFO.into())
        .from_env_lossy();
    let layer = fmt::layer().with_filter(filter);
    let subscriber = Registry::default().with(layer);
    set_global_default(subscriber)?;
    Ok(())
}

#[tauri::command]
pub(crate) async fn clear_logs(managed: tauri::State<'_, Managed>) -> StdResult<(), String> {
    clear_logs_inner(&managed).await.map_err(|e| e.to_string())
}

#[tauri::command]
pub(crate) async fn export_logs(managed: tauri::State<'_, Managed>) -> StdResult<(), String> {
    export_logs_inner(managed.ctlr_tx.clone())
        .await
        .map_err(|e| e.to_string())
}

#[derive(Clone, Default, Serialize)]
pub(crate) struct FileCount {
    bytes: u64,
    files: u64,
}

#[tauri::command]
pub(crate) async fn count_logs() -> StdResult<FileCount, String> {
    count_logs_inner().await.map_err(|e| e.to_string())
}

/// Delete all files in the logs directory.
///
/// This includes the current log file, so we won't write any more logs to disk
/// until the file rolls over or the app restarts.
pub(crate) async fn clear_logs_inner(managed: &Managed) -> Result<()> {
    let mut dir = tokio::fs::read_dir(log_path()?).await?;
    while let Some(entry) = dir.next_entry().await? {
        tokio::fs::remove_file(entry.path()).await?;
    }

    managed.fault_msleep(5000).await;
    Ok(())
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
    tracing::info!("Exporting logs to {path:?}");

    // TODO: Consider https://github.com/Majored/rs-async-zip/issues instead of `spawn_blocking`
    spawn_blocking(move || {
        let f = fs::File::create(path).context("Failed to create zip file")?;
        let mut zip = zip::ZipWriter::new(f);
        // All files will have the same modified time. Doing otherwise seems to be difficult
        let options = zip::write::FileOptions::default();
        let log_path = log_path().context("Failed to compute log dir path")?;
        for entry in fs::read_dir(log_path).context("Failed to `read_dir` log dir")? {
            let entry = entry.context("Got bad entry from `read_dir`")?;
            let Some(path) = stem.join(entry.file_name()).to_str().map(|x| x.to_owned()) else {
                bail!("log filename isn't valid Unicode")
            };
            zip.start_file(path, options)
                .context("`ZipWriter::start_file` failed")?;
            let mut f = fs::File::open(entry.path()).context("Failed to open log file")?;
            io::copy(&mut f, &mut zip).context("Failed to copy log file into zip")?;
        }
        zip.finish().context("Failed to finish zip file")?;
        Ok(())
    })
    .await
    .context("Failed to join zip export task")??;
    Ok(())
}

/// Count log files and their sizes
pub(crate) async fn count_logs_inner() -> Result<FileCount> {
    let mut dir = tokio::fs::read_dir(log_path()?).await?;
    let mut file_count = FileCount::default();

    while let Some(entry) = dir.next_entry().await? {
        let md = entry.metadata().await?;
        file_count.files += 1;
        file_count.bytes += md.len();
    }

    Ok(file_count)
}

/// Wrapper around `known_dirs::logs`
pub(crate) fn log_path() -> Result<PathBuf, Error> {
    known_dirs::logs().ok_or(Error::CantFindLocalAppDataFolder)
}
