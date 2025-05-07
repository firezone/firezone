//! Everything for logging to files, zipping up the files for export, and counting the files

use crate::gui::Managed;
use anyhow::{Context as _, Result, bail};
use firezone_bin_shared::known_dirs;
use firezone_logging::err_with_src;
use serde::Serialize;
use std::{
    fs,
    io::{self, ErrorKind::NotFound},
    path::{Path, PathBuf},
};
use tauri_plugin_dialog::DialogExt as _;
use tokio::task::spawn_blocking;
use tracing_subscriber::{Layer, Registry, layer::SubscriberExt};

use super::controller::{ControllerRequest, CtlrTx};

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
pub(crate) async fn count_logs() -> Result<FileCount, String> {
    count_logs_imp().await.map_err(|e| e.to_string())
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

/// If you don't store `Handles` in a variable, the file logger handle will drop immediately,
/// resulting in empty log files.
#[must_use]
pub struct Handles {
    pub logger: firezone_logging::file::Handle,
    pub reloader: firezone_logging::FilterReloadHandle,
}

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
pub enum Error {
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
pub fn setup(directives: &str) -> Result<Handles> {
    if let Err(error) = output_vt100::try_init() {
        tracing::debug!("Failed to init terminal colors: {error}");
    }

    let log_path = known_dirs::logs().context("Can't compute app log dir")?;
    std::fs::create_dir_all(&log_path).map_err(Error::CreateDirAll)?;

    // Logfilter for stdout cannot be reloaded. This is okay because we are using it only for local dev and debugging anyway.
    // Having multiple reload handles makes their type-signature quite complex so we don't bother with that.
    let (stdout_filter, stdout_reloader) = firezone_logging::try_filter(directives)?;
    let stdout_layer = tracing_subscriber::fmt::layer()
        .with_ansi(firezone_logging::stdout_supports_ansi())
        .event_format(firezone_logging::Format::new());

    let (system_filter, system_reloader) = firezone_logging::try_filter(directives)?;
    let system_layer = system_layer().context("Failed to init system logger")?;
    #[cfg(target_os = "linux")]
    let syslog_identifier = Some(system_layer.syslog_identifier().to_owned());
    #[cfg(not(target_os = "linux"))]
    let syslog_identifier = Option::<String>::None;

    let (file_layer, logger) = firezone_logging::file::layer(&log_path, "gui-client");
    let (file_filter, file_reloader) = firezone_logging::try_filter(directives)?;

    let subscriber = Registry::default()
        .with(file_layer.with_filter(file_filter))
        .with(stdout_layer.with_filter(stdout_filter))
        .with(system_layer.with_filter(system_filter))
        .with(firezone_logging::sentry_layer());
    firezone_logging::init(subscriber)?;

    tracing::info!(
        arch = std::env::consts::ARCH,
        os = std::env::consts::OS,
        version = env!("CARGO_PKG_VERSION"),
        %directives,
        system_uptime = firezone_bin_shared::uptime::get().map(tracing::field::debug),
        log_path = %log_path.display(),
        syslog_identifier = syslog_identifier.map(tracing::field::display),
        "`gui-client` started logging"
    );

    Ok(Handles {
        logger,
        reloader: stdout_reloader.merge(file_reloader).merge(system_reloader),
    })
}

#[cfg(target_os = "linux")]
fn system_layer() -> Result<tracing_journald::Layer> {
    let layer = tracing_journald::layer()?;

    Ok(layer)
}

#[cfg(not(target_os = "linux"))]
#[expect(clippy::unnecessary_wraps, reason = "Linux signature needs `Result`")]
fn system_layer() -> Result<tracing_subscriber::layer::Identity> {
    Ok(tracing_subscriber::layer::Identity::new())
}

#[derive(Clone, Default, Serialize)]
pub struct FileCount {
    bytes: u64,
    files: u64,
}

/// Delete all files in the logs directory.
///
/// This includes the current log file, so we won't write any more logs to disk
/// until the file rolls over or the app restarts.
///
/// If we get an error while removing a file, we still try to remove all other
/// files, then we return the most recent error.
pub async fn clear_gui_logs() -> Result<()> {
    firezone_headless_client::clear_logs(&known_dirs::logs().context("Can't compute GUI log dir")?)
        .await
}

/// Exports logs to a zip file
///
/// # Arguments
///
/// * `path` - Where the zip archive will be written
/// * `stem` - A directory containing all the log files inside the zip archive, to avoid creating a ["tar bomb"](https://www.linfo.org/tarbomb.html). This comes from the automatically-generated name of the archive, even if the user changes it to e.g. `logs.zip`
pub async fn export_logs_to(path: PathBuf, stem: PathBuf) -> Result<()> {
    tracing::info!("Exporting logs to {path:?}");
    let start = std::time::Instant::now();
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
    tracing::debug!(elapsed_s = ?start.elapsed(), "Exported logs");
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
async fn count_logs_imp() -> Result<FileCount> {
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
            src: known_dirs::ipc_service_logs().context("Can't compute IPC service logs dir")?,
            dst: PathBuf::from("connlib"),
        },
        LogPath {
            src: known_dirs::logs().context("Can't compute GUI log dir")?,
            dst: PathBuf::from("app"),
        },
    ])
}
