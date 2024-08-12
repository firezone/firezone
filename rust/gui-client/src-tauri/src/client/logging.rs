//! Everything for logging to files, zipping up the files for export, and counting the files

use crate::client::gui::{ControllerRequest, CtlrTx, Managed};
use anyhow::{bail, Context, Result};
use firezone_headless_client::known_dirs;
use serde::Serialize;
use std::{
    ffi::OsStr,
    fs,
    io::{self, ErrorKind::NotFound},
    path::{Path, PathBuf},
    result::Result as StdResult,
};
use tokio::task::spawn_blocking;
use tracing::subscriber::set_global_default;
use tracing_log::LogTracer;
use tracing_subscriber::{fmt, layer::SubscriberExt, reload, EnvFilter, Layer, Registry};

/// If you don't store `Handles` in a variable, the file logger handle will drop immediately,
/// resulting in empty log files.
#[must_use]
pub(crate) struct Handles {
    pub logger: firezone_logging::file::Handle,
    pub reloader: Reloader,
}

pub(crate) type Reloader = reload::Handle<EnvFilter, Registry>;

struct LogPath {
    /// Where to find the logs on disk
    ///
    /// e.g. `/var/log/dev.firezone.client`
    src: PathBuf,
    /// Where to store the logs in the zip
    ///
    /// e.g. `connlib`
    dst: PathBuf,
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum Error {
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
///
/// We need two of these filters for some reason, and `EnvFilter` doesn't implement
/// `Clone` yet, so that's why we take the directives string
/// <https://github.com/tokio-rs/tracing/issues/2360>
pub(crate) fn setup(directives: &str) -> Result<Handles> {
    let log_path = known_dirs::logs().context("Can't compute app log dir")?;

    std::fs::create_dir_all(&log_path).map_err(Error::CreateDirAll)?;
    let (layer, logger) = firezone_logging::file::layer(&log_path);
    let layer = layer.and_then(fmt::layer());
    let (filter, reloader) = reload::Layer::new(firezone_logging::try_filter(directives)?);
    let subscriber = Registry::default().with(layer.with_filter(filter));
    set_global_default(subscriber)?;
    if let Err(error) = output_vt100::try_init() {
        tracing::warn!(
            ?error,
            "Failed to init vt100 terminal colors (expected in release builds and in CI)"
        );
    }
    LogTracer::init()?;
    tracing::debug!(?log_path, "Log path");
    Ok(Handles { logger, reloader })
}

#[tauri::command]
pub(crate) async fn clear_logs() -> StdResult<(), String> {
    if let Err(error) = clear_logs_inner().await {
        // Log the error ourselves since Tauri will only log it to the JS console
        tracing::error!(?error, "Error while clearing logs");
        Err(error.to_string())
    } else {
        Ok(())
    }
}

#[tauri::command]
pub(crate) async fn export_logs(managed: tauri::State<'_, Managed>) -> StdResult<(), String> {
    show_export_dialog(managed.ctlr_tx.clone()).map_err(|e| e.to_string())
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
///
/// If we get an error while removing a file, we still try to remove all other
/// files, then we return the most recent error.
pub(crate) async fn clear_logs_inner() -> Result<()> {
    let mut result = Ok(());

    for log_path in log_paths()?.into_iter().map(|x| x.src) {
        let mut dir = match tokio::fs::read_dir(log_path).await {
            Ok(x) => x,
            Err(error) => {
                if matches!(error.kind(), NotFound) {
                    // In smoke tests, the IPC service runs in debug mode, so it won't write any logs to disk. If the IPC service's log dir doesn't exist, we shouldn't crash, it's correct to simply not delete the non-existent files
                    return Ok(());
                }
                // But any other error like permissions errors, should bubble.
                return Err(error.into());
            }
        };
        let mut paths = vec![];
        while let Some(entry) = dir.next_entry().await? {
            paths.push(entry.path());
        }

        let to_delete = choose_logs_to_delete(&paths);
        for path in &to_delete {
            if let Err(e) = tokio::fs::remove_file(path).await {
                result = Err(e);
            }
        }
    }

    Ok(result?)
}

fn choose_logs_to_delete(paths: &[PathBuf]) -> Vec<&Path> {
    let mut most_recent_stem = None;
    for path in paths {
        if path.extension() != Some(OsStr::new("log")) {
            continue;
        }
        let stem = path
            .file_stem()
            .expect("Every file in the log dir should have a stem");
        match most_recent_stem {
            None => most_recent_stem = Some(stem),
            Some(most_recent) if stem > most_recent => most_recent_stem = Some(stem),
            Some(_) => {}
        }
    }
    let Some(most_recent_stem) = most_recent_stem else {
        tracing::warn!(
            "Nothing to delete, should be impossible since both processes always write logs"
        );
        return vec![];
    };
    let most_recent_stem = most_recent_stem
        .to_str()
        .expect("Every file in the log dir should have a UTF-8 file name");

    paths
        .iter()
        .filter(|path| {
            let stem = path
                .file_stem()
                .expect("Every file in the log dir should have a stem");
            let stem = stem
                .to_str()
                .expect("Every file in the log dir should have a UTF-8 file name");
            if !stem.starts_with("connlib.") {
                return false;
            }
            stem < most_recent_stem
        })
        .map(|x| x.as_path())
        .collect()
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

/// Exports logs to a zip file
///
/// # Arguments
///
/// * `path` - Where the zip archive will be written
/// * `stem` - A directory containing all the log files inside the zip archive, to avoid creating a ["tar bomb"](https://www.linfo.org/tarbomb.html). This comes from the automatically-generated name of the archive, even if the user changes it to e.g. `logs.zip`
pub(crate) async fn export_logs_to(path: PathBuf, stem: PathBuf) -> Result<()> {
    tracing::info!("Exporting logs to {path:?}");
    // Use a temp path so that if the export fails we don't end up with half a zip file
    let temp_path = path.with_extension(".zip-partial");

    // TODO: Consider https://github.com/Majored/rs-async-zip/issues instead of `spawn_blocking`
    spawn_blocking(move || {
        let f = fs::File::create(&temp_path).context("Failed to create zip file")?;
        let mut zip = zip::ZipWriter::new(f);
        for log_path in log_paths().context("Can't compute log paths")? {
            add_dir_to_zip(&mut zip, &log_path.src, &stem.join(log_path.dst))?;
        }
        zip.finish().context("Failed to finish zip file")?;
        fs::rename(&temp_path, &path)?;
        Ok::<_, anyhow::Error>(())
    })
    .await
    .context("Failed to join zip export task")??;
    Ok(())
}

/// Reads all files in a directory and adds them to a zip file
///
/// Does not recurse.
/// All files will have the same modified time. Doing otherwise seems to be difficult
fn add_dir_to_zip(
    zip: &mut zip::ZipWriter<std::fs::File>,
    src_dir: &Path,
    dst_stem: &Path,
) -> Result<()> {
    let options = zip::write::SimpleFileOptions::default();
    let dir = match fs::read_dir(src_dir) {
        Ok(x) => x,
        Err(error) => {
            if matches!(error.kind(), NotFound) {
                // In smoke tests, the IPC service runs in debug mode, so it won't write any logs to disk. If the IPC service's log dir doesn't exist, we shouldn't crash, it's correct to simply not add any files to the zip
                return Ok(());
            }
            // But any other error like permissions errors, should bubble.
            return Err(error.into());
        }
    };
    for entry in dir {
        let entry = entry.context("Got bad entry from `read_dir`")?;
        let Some(path) = dst_stem
            .join(entry.file_name())
            .to_str()
            .map(|x| x.to_owned())
        else {
            bail!("log filename isn't valid Unicode")
        };
        zip.start_file(path, options)
            .context("`ZipWriter::start_file` failed")?;
        let mut f = fs::File::open(entry.path()).context("Failed to open log file")?;
        io::copy(&mut f, zip).context("Failed to copy log file into zip")?;
    }
    Ok(())
}

/// Count log files and their sizes
pub(crate) async fn count_logs_inner() -> Result<FileCount> {
    // I spent about 5 minutes on this and couldn't get it to work with `Stream`
    let mut total_count = FileCount::default();
    for log_path in log_paths()? {
        let count = count_one_dir(&log_path.src).await?;
        total_count.files += count.files;
        total_count.bytes += count.bytes;
    }
    Ok(total_count)
}

async fn count_one_dir(path: &Path) -> Result<FileCount> {
    let mut dir = tokio::fs::read_dir(path).await?;
    let mut file_count = FileCount::default();

    while let Some(entry) = dir.next_entry().await? {
        let md = entry.metadata().await?;
        file_count.files += 1;
        file_count.bytes += md.len();
    }

    Ok(file_count)
}

fn log_paths() -> Result<Vec<LogPath>> {
    Ok(vec![
        LogPath {
            src: firezone_headless_client::known_dirs::ipc_service_logs()
                .context("Can't compute IPC service logs dir")?,
            dst: PathBuf::from("connlib"),
        },
        LogPath {
            src: known_dirs::logs().context("Can't compute app log dir")?,
            dst: PathBuf::from("app"),
        },
    ])
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    #[test]
    fn clear_logs_logic() {
        // These are out of order just to make sure it works anyway
        let paths: Vec<_> = [
            "connlib.2024-08-05-19-41-46.jsonl",
            "connlib.2024-08-05-19-41-46.log",
            "connlib.2024-08-07-14-17-56.jsonl",
            "connlib.2024-08-07-14-17-56.log",
            "connlib.2024-08-06-14-21-13.jsonl",
            "connlib.2024-08-06-14-21-13.log",
            "connlib.2024-08-06-14-51-19.jsonl",
            "connlib.2024-08-06-14-51-19.log",
            "crash.2024-07-22-21-16-20.dmp",
            "last_crash.dmp",
        ]
        .into_iter()
        .map(|x| Path::new("/bogus").join(x))
        .collect();
        let to_delete = super::choose_logs_to_delete(&paths);
        assert_eq!(
            to_delete,
            [
                "/bogus/connlib.2024-08-05-19-41-46.jsonl",
                "/bogus/connlib.2024-08-05-19-41-46.log",
                "/bogus/connlib.2024-08-06-14-21-13.jsonl",
                "/bogus/connlib.2024-08-06-14-21-13.log",
                "/bogus/connlib.2024-08-06-14-51-19.jsonl",
                "/bogus/connlib.2024-08-06-14-51-19.log",
            ]
            .into_iter()
            .map(Path::new)
            .collect::<Vec<_>>()
        );
    }
}
