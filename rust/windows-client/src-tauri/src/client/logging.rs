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

pub(crate) const CONNLIB_CRASH_DUMP: &str = "connlib_last_crash.dmp";
pub(crate) const CONNLIB_DIR: &str = "connlib_logs";
pub(crate) const GUI_CRASH_DUMP: &str = "gui_last_crash.dmp";
pub(crate) const GUI_DIR: &str = "gui_logs";
pub(crate) const UNKNOWN_CRASH_DUMP: &str = "unknown_last_crash.dmp";

/// Set up logs for the first time.
/// Must be called after the app has changed directory to AppData/Local/dev.firezone.client/data
pub(crate) fn setup(log_filter: &str, dir_name: &str) -> Result<Handles> {
    let (layer, logger) = file_logger::layer(Path::new(dir_name));
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
    let mut dir = tokio::fs::read_dir("logs").await?;
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
    tracing::trace!("Exporting logs to {path:?}");

    // TODO: Consider https://github.com/Majored/rs-async-zip/issues instead of `spawn_blocking`
    spawn_blocking(move || {
        let mut builder = ZipBuilder::new(&path, stem)?;

        builder.add_file(CONNLIB_CRASH_DUMP)?;
        builder.add_dir(CONNLIB_DIR)?;

        builder.add_file(GUI_CRASH_DUMP)?;
        builder.add_dir(GUI_DIR)?;

        builder.add_file(UNKNOWN_CRASH_DUMP)?;

        builder.finish()?;
        Ok::<_, anyhow::Error>(())
    })
    .await??;

    // TODO: Somehow signal back to the GUI to unlock the log buttons when the export completes, or errors out
    Ok(())
}

struct ZipBuilder {
    options: zip::write::FileOptions,
    stem: PathBuf,
    zip: zip::ZipWriter<std::fs::File>,
}

impl ZipBuilder {
    fn new(path: &Path, stem: PathBuf) -> Result<Self> {
        let f = fs::File::create(path)?;
        // All files will have the same modified time. Doing otherwise seems to be difficult
        let options = zip::write::FileOptions::default();
        let zip = zip::ZipWriter::new(f);

        Ok(Self { options, stem, zip })
    }

    fn finish(mut self) -> Result<()> {
        self.zip.finish()?;
        Ok(())
    }

    // Using `&str` here so the paths can be const
    fn add_dir(&mut self, dir: &str) -> Result<()> {
        for entry in fs::read_dir(Path::new(dir))? {
            let entry = entry?;
            let zipped_path = self
                .stem
                .join(dir)
                .join(entry.file_name())
                .to_str()
                .map(|x| x.to_owned())
                .ok_or_else(|| anyhow::anyhow!("couldn't construct `zipped_path`"))?;
            self.zip.start_file(zipped_path, self.options)?;
            let mut f = fs::File::open(entry.path())?;
            io::copy(&mut f, &mut self.zip)?;
        }
        Ok(())
    }

    // Using `&str` here so the paths can be const
    fn add_file(&mut self, name: &str) -> Result<()> {
        let Ok(mut f) = fs::File::open(name) else {
            // Maybe the file just doesn't exist, that's fine.
            return Ok(());
        };

        let zipped_path = self
            .stem
            .join(name)
            .to_str()
            .map(|x| x.to_owned())
            .ok_or_else(|| anyhow::anyhow!("couldn't construct `zipped_path`"))?;
        self.zip.start_file(zipped_path, self.options)?;
        io::copy(&mut f, &mut self.zip)?;
        Ok(())
    }
}

/// Count log files and their sizes
pub(crate) async fn count_logs_inner() -> Result<FileCount> {
    let mut file_count = FileCount::default();

    count_file(&mut file_count, CONNLIB_CRASH_DUMP).await?;
    count_logs_in_dir(&mut file_count, CONNLIB_DIR).await?;

    count_file(&mut file_count, GUI_CRASH_DUMP).await?;
    count_logs_in_dir(&mut file_count, GUI_DIR).await?;

    count_file(&mut file_count, UNKNOWN_CRASH_DUMP).await?;

    Ok(file_count)
}

async fn count_logs_in_dir(file_count: &mut FileCount, path: &str) -> Result<()> {
    let mut dir = tokio::fs::read_dir(path).await?;
    while let Some(entry) = dir.next_entry().await? {
        let md = entry.metadata().await?;
        file_count.files += 1;
        file_count.bytes += md.len();
    }
    Ok(())
}

async fn count_file(file_count: &mut FileCount, name: &str) -> Result<()> {
    let Ok(md) = tokio::fs::metadata(name).await else {
        // It's okay if the file doesn't exist
        return Ok(());
    };
    file_count.files += 1;
    file_count.bytes += md.len();
    Ok(())
}
