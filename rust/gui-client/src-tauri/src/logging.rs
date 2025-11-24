//! Everything for logging to files, zipping up the files for export, and counting the files

pub use ::logging::*;

use anyhow::{Context as _, Result, bail};
use bin_shared::known_dirs;
use serde::Serialize;
use std::{
    fs,
    io::{self, ErrorKind::NotFound},
    path::{Path, PathBuf},
};
use tokio::task::spawn_blocking;
use tracing_subscriber::{EnvFilter, Layer, Registry, layer::SubscriberExt};

/// If you don't store `Handles` in a variable, the file logger handle will drop immediately,
/// resulting in empty log files.
#[must_use]
pub struct Handles {
    pub logger: logging::file::Handle,
    pub reloader: FilterReloadHandle,
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
pub fn setup_gui(directives: &str) -> Result<Handles> {
    if let Err(error) = output_vt100::try_init() {
        tracing::debug!("Failed to init terminal colors: {error}");
    }

    let log_path = known_dirs::logs().context("Can't compute app log dir")?;
    std::fs::create_dir_all(&log_path).map_err(Error::CreateDirAll)?;

    // Logfilter for stdout cannot be reloaded. This is okay because we are using it only for local dev and debugging anyway.
    // Having multiple reload handles makes their type-signature quite complex so we don't bother with that.
    let (stdout_filter, stdout_reloader) = logging::try_filter(directives)?;
    let stdout_layer = tracing_subscriber::fmt::layer()
        .with_ansi(logging::stdout_supports_ansi())
        .event_format(logging::Format::new());

    let (system_filter, system_reloader) = logging::try_filter(directives)?;
    let system_layer = system_layer().context("Failed to init system logger")?;
    #[cfg(target_os = "linux")]
    let syslog_identifier = Some(system_layer.syslog_identifier().to_owned());
    #[cfg(not(target_os = "linux"))]
    let syslog_identifier = Option::<String>::None;

    let (file_layer, logger) = logging::file::layer(&log_path, "gui-client");
    let (file_filter, file_reloader) = logging::try_filter(directives)?;

    let subscriber = Registry::default()
        .with(file_layer.with_filter(file_filter))
        .with(stdout_layer.with_filter(stdout_filter))
        .with(system_layer.with_filter(system_filter))
        .with(logging::sentry_layer());
    logging::init(subscriber)?;

    tracing::info!(
        arch = std::env::consts::ARCH,
        os = std::env::consts::OS,
        version = env!("CARGO_PKG_VERSION"),
        %directives,
        system_uptime = bin_shared::uptime::get().map(tracing::field::debug),
        log_path = %log_path.display(),
        syslog_identifier = syslog_identifier.map(tracing::field::display),
        "`gui-client` started logging"
    );

    Ok(Handles {
        logger,
        reloader: stdout_reloader.merge(file_reloader).merge(system_reloader),
    })
}

/// Starts logging for the production Tunnel service
///
/// Returns: A `Handle` that must be kept alive. Dropping it stops logging
/// and flushes the log file.
pub fn setup_tunnel(
    log_path: Option<PathBuf>,
) -> Result<(logging::file::Handle, logging::FilterReloadHandle)> {
    // If `log_dir` is Some, use that. Else call `tunnel_service_logs`
    let log_path = log_path.map_or_else(
        || {
            known_dirs::tunnel_service_logs()
                .context("Should be able to compute Tunnel service logs dir")
        },
        Ok,
    )?;
    std::fs::create_dir_all(&log_path)
        .context("We should have permissions to create our log dir")?;

    let directives = get_log_filter().context("Couldn't read log filter")?;

    let (file_filter, file_reloader) = logging::try_filter(&directives)?;
    let (stdout_filter, stdout_reloader) = logging::try_filter(&directives)?;

    let (file_layer, file_handle) = logging::file::layer(&log_path, "tunnel-service");

    let stdout_layer = tracing_subscriber::fmt::layer()
        .with_ansi(logging::stdout_supports_ansi())
        .event_format(logging::Format::new().without_timestamp());

    let subscriber = Registry::default()
        .with(file_layer.with_filter(file_filter))
        .with(stdout_layer.with_filter(stdout_filter))
        .with(logging::sentry_layer());
    logging::init(subscriber)?;

    tracing::info!(
        arch = std::env::consts::ARCH,
        os = std::env::consts::OS,
        version = env!("CARGO_PKG_VERSION"),
        ?directives,
        system_uptime = bin_shared::uptime::get().map(tracing::field::debug),
        log_path = %log_path.display(),
        "`tunnel service` started logging"
    );

    Ok((file_handle, file_reloader.merge(stdout_reloader)))
}

/// Sets up logging for stdout only, with INFO level by default
pub fn setup_stdout() -> Result<FilterReloadHandle> {
    let directives = get_log_filter().context("Can't read log filter")?;
    let (filter, reloader) = logging::try_filter(&directives)?;
    let layer = tracing_subscriber::fmt::layer()
        .event_format(logging::Format::new())
        .with_filter(filter);
    let subscriber = Registry::default().with(layer);
    logging::init(subscriber)?;

    Ok(reloader)
}
/// Reads the log filter for the Tunnel service or for debug commands
///
/// e.g. `info`
///
/// Reads from:
/// 1. `RUST_LOG` env var
/// 2. `known_dirs::tunnel_log_filter()` file
/// 3. Hard-coded default `SERVICE_RUST_LOG`
///
/// Errors if something is badly wrong, e.g. the directory for the config file
/// can't be computed
pub(crate) fn get_log_filter() -> Result<String> {
    #[cfg(not(debug_assertions))]
    const DEFAULT_LOG_FILTER: &str = "info";
    #[cfg(debug_assertions)]
    const DEFAULT_LOG_FILTER: &str = "debug";

    if let Ok(filter) = std::env::var(EnvFilter::DEFAULT_ENV) {
        return Ok(filter);
    }

    if let Ok(filter) = std::fs::read_to_string(bin_shared::known_dirs::tunnel_log_filter()?)
        .map(|s| s.trim().to_string())
    {
        return Ok(filter);
    }

    Ok(DEFAULT_LOG_FILTER.to_string())
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

#[derive(Clone, Default, Serialize, specta::Type)]
pub struct FileCount {
    bytes: u64,
    files: u64,
}

pub async fn clear_gui_logs() -> Result<()> {
    clear_logs(&known_dirs::logs().context("Can't compute GUI log dir")?).await
}

pub async fn clear_service_logs() -> Result<()> {
    clear_logs(&known_dirs::tunnel_service_logs().context("Can't compute service logs dir")?).await
}

/// Deletes all `.log` files in `path`.
async fn clear_logs(path: &Path) -> Result<()> {
    let mut dir = match tokio::fs::read_dir(path).await {
        Ok(x) => x,
        Err(error) => {
            if matches!(error.kind(), NotFound) {
                // In smoke tests, the Tunnel service runs in debug mode, so it won't write any logs to disk. If the Tunnel service's log dir doesn't exist, we shouldn't crash, it's correct to simply not delete the non-existent files
                return Ok(());
            }
            // But any other error like permissions errors, should bubble.
            return Err(error.into());
        }
    };

    let mut result = Ok(());

    // If we can't delete some files due to permission errors, just keep going
    // and delete as much as we can, then return the most recent error
    while let Some(entry) = dir
        .next_entry()
        .await
        .context("Failed to read next dir entry")?
    {
        if entry
            .file_name()
            .to_str()
            .is_none_or(|name| !name.ends_with("log") && name != "latest")
        {
            continue;
        }

        if let Err(e) = tokio::fs::remove_file(entry.path()).await {
            result = Err(e);
        }
    }

    result.context("Failed to delete at least one file")
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
                // In smoke tests, the Tunnel service runs in debug mode, so it won't write any logs to disk. If the Tunnel service's log dir doesn't exist, we shouldn't crash, it's correct to simply not add any files to the zip
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
    let mut dir = match tokio::fs::read_dir(path).await {
        Ok(dir) => dir,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(FileCount::default()),
        Err(e) => return Err(anyhow::Error::new(e)),
    };

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
            src: known_dirs::tunnel_service_logs()
                .context("Can't compute Tunnel service logs dir")?,
            dst: PathBuf::from("connlib"),
        },
        LogPath {
            src: known_dirs::logs().context("Can't compute GUI log dir")?,
            dst: PathBuf::from("app"),
        },
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn only_deletes_log_files() {
        let dir = tempfile::tempdir().unwrap();

        std::fs::write(dir.path().join("first.log"), "log file 1").unwrap();
        std::fs::write(dir.path().join("second.log"), "log file 1").unwrap();
        std::fs::write(dir.path().join("not_a_logfile.tmp"), "something important").unwrap();

        clear_logs(dir.path()).await.unwrap();

        assert_eq!(
            std::fs::read_to_string(dir.path().join("not_a_logfile.tmp")).unwrap(),
            "something important"
        );
    }

    #[tokio::test]
    async fn non_existing_path_is_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_owned();
        drop(dir);

        let file_count = count_one_dir(path.as_path()).await.unwrap();

        assert_eq!(file_count.bytes, 0);
        assert_eq!(file_count.files, 0);
    }
}
