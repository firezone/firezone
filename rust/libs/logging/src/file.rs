//! Connlib File Logger
//!
//! This module implements a file-based logger for connlib using tracing-appender.
//!
//! The log files are never rotated for the duration of the process; this prevents
//! tracing_appender from trying to prune old log files which triggers privacy
//! alerts in Apple app store submissions.
//!
//! Since these will be leaving the user's device, these logs should contain *only*
//! the necessary debugging information, and **not** any sensitive information,
//! including but not limited to:
//! - WiFi SSIDs
//! - Location information
//! - Device names
//! - Device serials
//! - MAC addresses

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::{fs, io};

use anyhow::Context;
use time::OffsetDateTime;
use tracing::Subscriber;
use tracing_appender::non_blocking::{NonBlocking, WorkerGuard};
use tracing_subscriber::Layer;

use crate::unwrap_or_debug;

pub const TIME_FORMAT: &str = "[year]-[month]-[day]-[hour]-[minute]-[second]";

/// How many lines we will at most buffer in the channel with the background thread that writes to disk.
///
/// We don't need this number to be very high because:
/// a. `connlib` doesn't actually log a lot
/// b. The background continuously reads from the channel and writes to disk.
///
/// This buffer only needs to be able to handle bursts.
///
/// As per docs on [`tracing_appender::non_blocking::DEFAULT_BUFFERED_LINES_LIMIT`], this is a power of 2.
const MAX_BUFFERED_LINES: usize = 1024;

/// Create a new file logger layer.
pub fn layer<T>(
    log_dir: &Path,
    file_base_name: &'static str,
) -> (Box<dyn Layer<T> + Send + Sync + 'static>, Handle)
where
    T: Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    let (appender_fmt, handle_fmt) = new_appender(log_dir.to_path_buf(), file_base_name, "log");
    let layer_fmt = tracing_subscriber::fmt::layer()
        .with_ansi(false)
        .with_writer(appender_fmt)
        .event_format(crate::Format::new())
        .boxed();

    let handle = Handle {
        _guard_fmt: Arc::new(handle_fmt),
    };

    // Return the guard so that the caller maintains a handle to it. Otherwise,
    // we have to wait for tracing_appender to flush the logs before exiting.
    // See https://docs.rs/tracing-appender/latest/tracing_appender/non_blocking/struct.WorkerGuard.html
    (layer_fmt, handle)
}

fn new_appender(
    directory: PathBuf,
    file_base_name: &'static str,
    file_extension: &'static str,
) -> (NonBlocking, WorkerGuard) {
    let appender = Appender {
        directory,
        current: None,
        file_extension,
        file_base_name,
    };

    let (non_blocking, guard) = tracing_appender::non_blocking::NonBlockingBuilder::default()
        .buffered_lines_limit(MAX_BUFFERED_LINES)
        .finish(appender);

    (non_blocking, guard)
}

/// A handle to our file-logger.
///
/// This handle houses the [`WorkerGuard`]s of the underlying non-blocking appenders.
/// Thus, you MUST NOT drop this handle for as long as you want messages to arrive at the log files.
#[must_use]
#[derive(Clone, Debug)]
pub struct Handle {
    _guard_fmt: Arc<WorkerGuard>,
}

#[derive(Debug)]
struct Appender {
    directory: PathBuf,
    file_base_name: &'static str,
    file_extension: &'static str,
    // Leaving this so that I/O errors come up through `write` instead of panicking
    // in `layer`
    current: Option<(fs::File, String)>,
}

impl Appender {
    fn with_current_file<R>(
        &mut self,
        cb: impl Fn(&mut fs::File) -> io::Result<R>,
    ) -> io::Result<R> {
        match self.current.as_mut() {
            None => {
                let (mut file, name) = self.create_new_writer()?;

                let ret = cb(&mut file);

                self.current = Some((file, name));

                ret
            }
            Some((_, filename))
                if !std::fs::exists(self.directory.join(&filename)).unwrap_or_default() =>
            {
                let (mut file, name) = self.create_new_writer()?;

                let ret = cb(&mut file);

                self.current = Some((file, name));

                ret
            }
            Some((file, _)) => cb(file),
        }
    }

    // Inspired from `tracing-appender/src/rolling.rs`.
    fn create_new_writer(&self) -> io::Result<(fs::File, String)> {
        let format = time::format_description::parse(TIME_FORMAT).map_err(io::Error::other)?;
        let date = OffsetDateTime::now_utc()
            .format(&format)
            .map_err(|_| io::Error::other("Failed to format timestamp"))?;

        let filename = format!("{}.{date}.{}", self.file_base_name, self.file_extension);

        let path = self.directory.join(&filename);
        let latest = self.directory.join("latest");
        let mut open_options = fs::OpenOptions::new();
        open_options.append(true).create(true);

        let new_file = open_options.open(path.as_path());
        if new_file.is_err()
            && let Some(parent) = path.parent()
        {
            fs::create_dir_all(parent)?;
            let file = open_options.open(path)?;

            return Ok((file, filename));
        }

        let file = new_file?;
        Self::set_permissions(&file)?;

        let _ = std::fs::remove_file(&latest);

        #[cfg(unix)]
        unwrap_or_debug!(
            std::os::unix::fs::symlink(path, latest)
                .context("Failed to create `latest` link to log file"),
            "{}"
        );
        #[cfg(windows)]
        unwrap_or_debug!(
            std::os::windows::fs::symlink_file(path, latest)
                .context("Failed to create `latest` link to log file"),
            "{}"
        );

        Ok((file, filename))
    }

    /// Make the logs group-readable so that the GUI, running as a user in the `firezone`
    /// group, can zip them up when exporting logs.
    #[cfg(target_os = "linux")]
    fn set_permissions(f: &fs::File) -> io::Result<()> {
        // I would put this at the top of the file, but it only exists on Linux
        use std::os::unix::fs::PermissionsExt;
        // user read/write, group read-only, others nothing
        let perms = fs::Permissions::from_mode(0o640);
        f.set_permissions(perms)?;
        Ok(())
    }

    /// Does nothing on non-Linux systems
    #[cfg(not(target_os = "linux"))]
    #[expect(clippy::unnecessary_wraps)]
    fn set_permissions(_f: &fs::File) -> io::Result<()> {
        Ok(())
    }
}

impl io::Write for Appender {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.with_current_file(|f| f.write(buf))
    }

    fn flush(&mut self) -> io::Result<()> {
        self.with_current_file(|f| f.flush())
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

    use super::*;

    #[test]
    fn deleting_log_file_creates_new_one() {
        let dir = tempfile::tempdir().unwrap();

        let (layer, _handle) = layer(dir.path(), "connlib");

        let _guard = tracing_subscriber::registry()
            .with(layer)
            .with(tracing_subscriber::EnvFilter::from("info"))
            .set_default();

        tracing::info!("This is a test");
        std::thread::sleep(Duration::from_millis(1000)); // Wait a bit until background thread has flushed the log.

        for dir in std::fs::read_dir(dir.path()).unwrap() {
            let dir = dir.unwrap();

            std::fs::remove_file(dir.path()).unwrap();
        }

        tracing::info!("Write after delete");
        std::thread::sleep(Duration::from_millis(1000)); // Wait a bit until background thread has flushed the log.

        let content = std::fs::read_to_string(dir.path().join("latest")).unwrap();

        assert!(content.contains("Write after delete"))
    }
}
