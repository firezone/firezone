//! Everything for logging to files, zipping up the files for export, and counting the files

use anyhow::{bail, Context as _, Result};
use firezone_headless_client::{known_dirs, LogFilterReloader};
use firezone_logging::err_with_src;
use serde::Serialize;
use std::{
    fs,
    io::{self, ErrorKind::NotFound},
    path::{Path, PathBuf},
};
use tokio::task::spawn_blocking;
use tracing_subscriber::{layer::SubscriberExt, reload, Layer, Registry};

/// If you don't store `Handles` in a variable, the file logger handle will drop immediately,
/// resulting in empty log files.
#[must_use]
pub struct Handles {
    pub logger: firezone_logging::file::Handle,
    pub reloader: LogFilterReloader,
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

    // Logfilter for stderr cannot be reloaded. This is okay because we are using it only for local dev and debugging anyway.
    // Having multiple reload handles makes their type-signature quite complex so we don't bother with that.
    let stderr = tracing_subscriber::fmt::layer()
        .event_format(firezone_logging::Format::new())
        .with_filter(firezone_logging::try_filter(directives)?);

    std::fs::create_dir_all(&log_path).map_err(Error::CreateDirAll)?;
    let (layer, logger) = firezone_logging::file::layer(&log_path, "gui-client");
    let (filter, reloader) = reload::Layer::new(firezone_logging::try_filter(directives)?);

    let subscriber = Registry::default()
        .with(layer.with_filter(filter))
        .with(stderr)
        .with(firezone_logging::sentry_layer());
    firezone_logging::init(subscriber)?;

    tracing::debug!(log_path = %log_path.display(), "Log path");

    Ok(Handles { logger, reloader })
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
pub async fn count_logs() -> Result<FileCount> {
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
