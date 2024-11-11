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

use time::OffsetDateTime;
use tracing::Subscriber;
use tracing_appender::non_blocking::{NonBlocking, WorkerGuard};
use tracing_subscriber::Layer;

const LOG_FILE_BASE_NAME: &str = "connlib";
pub const TIME_FORMAT: &str = "[year]-[month]-[day]-[hour]-[minute]-[second]";

/// Create a new file logger layer.
pub fn layer<T>(log_dir: &Path) -> (Box<dyn Layer<T> + Send + Sync + 'static>, Handle)
where
    T: Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    let (appender_json, handle_json) = new_appender(log_dir.to_path_buf(), "jsonl");
    let layer_json = tracing_stackdriver::layer()
        .with_writer(appender_json)
        .boxed();

    let (appender_fmt, handle_fmt) = new_appender(log_dir.to_path_buf(), "log");
    let layer_fmt = tracing_subscriber::fmt::layer()
        .with_writer(appender_fmt)
        .event_format(crate::Format::new().without_ansi())
        .boxed();

    let handle = Handle {
        _guard_json: Arc::new(handle_json),
        _guard_fmt: Arc::new(handle_fmt),
    };

    // Return the guard so that the caller maintains a handle to it. Otherwise,
    // we have to wait for tracing_appender to flush the logs before exiting.
    // See https://docs.rs/tracing-appender/latest/tracing_appender/non_blocking/struct.WorkerGuard.html
    (vec![layer_json, layer_fmt].boxed(), handle)
}

fn new_appender(directory: PathBuf, file_extension: &'static str) -> (NonBlocking, WorkerGuard) {
    let appender = Appender {
        directory,
        current: None,
        file_extension,
    };

    let (non_blocking, guard) = tracing_appender::non_blocking(appender);

    (non_blocking, guard)
}

/// A handle to our file-logger.
///
/// This handle houses the [`WorkerGuard`]s of the underlying non-blocking appenders.
/// Thus, you MUST NOT drop this handle for as long as you want messages to arrive at the log files.
#[must_use]
#[derive(Clone, Debug)]
pub struct Handle {
    _guard_json: Arc<WorkerGuard>,
    _guard_fmt: Arc<WorkerGuard>,
}

#[derive(Debug)]
struct Appender {
    directory: PathBuf,
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
            Some((file, _)) => cb(file),
        }
    }

    // Inspired from `tracing-appender/src/rolling.rs`.
    fn create_new_writer(&self) -> io::Result<(fs::File, String)> {
        let format = time::format_description::parse(TIME_FORMAT).map_err(io::Error::other)?;
        let date = OffsetDateTime::now_utc()
            .format(&format)
            .map_err(|_| io::Error::other("Failed to format timestamp"))?;

        let filename = format!("{LOG_FILE_BASE_NAME}.{date}.{}", self.file_extension);

        let path = self.directory.join(&filename);
        let mut open_options = fs::OpenOptions::new();
        open_options.append(true).create(true);

        let new_file = open_options.open(path.as_path());
        if new_file.is_err() {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent)?;
                let file = open_options.open(path)?;

                return Ok((file, filename));
            }
        }

        let file = new_file?;
        Self::set_permissions(&file)?;

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
