//! Connlib File Logger
//!
//! This module implements a file-based logger for connlib using tracing-appender.
//!
//! The log files are rotated hourly.
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
use std::sync::{Arc, Mutex, MutexGuard};
use std::{fs, io};

use time::OffsetDateTime;
use tracing::Subscriber;
use tracing_appender::non_blocking::{NonBlocking, WorkerGuard};
use tracing_subscriber::Layer;

const LOG_FILE_BASE_NAME: &str = "connlib";

/// Create a new file logger layer.
pub fn layer<T>(log_dir: &Path) -> (Box<dyn Layer<T> + Send + Sync + 'static>, Handle)
where
    T: Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    let (appender, handle) = new_appender(log_dir.to_path_buf());
    let layer = tracing_stackdriver::layer().with_writer(appender).boxed();

    // Return the guard so that the caller maintains a handle to it. Otherwise,
    // we have to wait for tracing_appender to flush the logs before exiting.
    // See https://docs.rs/tracing-appender/latest/tracing_appender/non_blocking/struct.WorkerGuard.html
    (layer, handle)
}

fn new_appender(directory: PathBuf) -> (NonBlocking, Handle) {
    let inner = Arc::new(Mutex::new(Inner {
        directory,
        current: None,
    }));
    let appender = Appender {
        inner: inner.clone(),
    };

    let (non_blocking, guard) = tracing_appender::non_blocking(appender);
    let handle = Handle {
        inner,
        _guard: Arc::new(guard),
    };

    (non_blocking, handle)
}

/// A handle to our file-logger.
///
/// This handle allows to roll over logging to a new file via [`Handle::roll_to_new_file`]. It also houses the [`WorkerGuard`] of the underlying non-blocking appender.
/// Thus, you MUST NOT drop this handle for as long as you want messages to arrive at the log file.
#[derive(Clone, Debug)]
pub struct Handle {
    inner: Arc<Mutex<Inner>>,
    _guard: Arc<WorkerGuard>,
}

impl Handle {
    /// Rolls over to a new file.
    ///
    /// Returns the path to the now unused, previous log file.
    /// If we don't have a log-file yet, `Ok(None)` is returned.
    pub fn roll_to_new_file(&self) -> io::Result<Option<PathBuf>> {
        let mut inner = try_unlock(&self.inner);
        let new_writer = inner.create_new_writer()?;
        let Some((_, name)) = inner.current.replace(new_writer) else {
            return Ok(None);
        };

        Ok(Some(inner.directory.join(name)))
    }
}

#[derive(Debug)]
struct Appender {
    inner: Arc<Mutex<Inner>>,
}

#[derive(Debug)]
struct Inner {
    directory: PathBuf,
    current: Option<(fs::File, String)>,
}

impl Inner {
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
        let format =
            time::format_description::parse("[year]-[month]-[day]-[hour]-[minute]-[second]")
                .expect("static format description to be valid");
        let date = OffsetDateTime::now_utc()
            .format(&format)
            .expect("static format description to be valid");

        let filename = format!("{LOG_FILE_BASE_NAME}.{date}.log");

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

        Ok((file, filename))
    }
}

impl io::Write for Appender {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        try_unlock(&self.inner).with_current_file(|f| f.write(buf))
    }

    fn flush(&mut self) -> io::Result<()> {
        try_unlock(&self.inner).with_current_file(|f| f.flush())
    }
}

fn try_unlock(inner: &Mutex<Inner>) -> MutexGuard<'_, Inner> {
    inner.lock().unwrap_or_else(|e| e.into_inner())
}
