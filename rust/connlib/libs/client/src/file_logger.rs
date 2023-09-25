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
use std::sync::{Arc, Mutex};
use std::{fs, io};
use tracing::{level_filters::LevelFilter, Subscriber};
use tracing_subscriber::Layer;

const LOG_FILE_BASE_NAME: &str = "connlib.log";

/// Create a new file logger layer.
pub fn layer<T>(
    log_dir: &Path,
) -> (
    Box<dyn Layer<T> + Send + Sync + 'static>,
    tracing_appender::non_blocking::WorkerGuard,
    Handle,
)
where
    T: Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    #[cfg(debug_assertions)]
    let level = LevelFilter::DEBUG;

    #[cfg(not(debug_assertions))]
    let level = LevelFilter::WARN;

    let (appender, handle) = new_appender(log_dir.to_path_buf(), LOG_FILE_BASE_NAME.to_owned());

    let (writer, guard) = tracing_appender::non_blocking(appender);

    let layer = tracing_stackdriver::layer()
        .with_writer(writer)
        .with_filter(level)
        .boxed();

    // Return the guard so that the caller maintains a handle to it. Otherwise,
    // we have to wait for tracing_appender to flush the logs before exiting.
    // See https://docs.rs/tracing-appender/latest/tracing_appender/non_blocking/struct.WorkerGuard.html
    (layer, guard, handle)
}

fn new_appender(directory: PathBuf, name: String) -> (Appender, Handle) {
    let inner = Arc::new(Mutex::new(Inner { directory, name }));
    let appender = Appender {
        inner: inner.clone(),
    };
    let handle = Handle { inner };

    (appender, handle)
}

#[derive(Clone, Debug)]
pub struct Handle {
    inner: Arc<Mutex<Inner>>,
}

#[derive(Debug)]
struct Appender {
    inner: Arc<Mutex<Inner>>,
}

impl Handle {
    /// Rolls over to a new file.
    ///
    /// Returns the path to the now unused, previous log file.
    pub fn roll_to_new_file(&self) -> PathBuf {
        todo!()
    }
}

#[derive(Debug)]
struct Inner {
    directory: PathBuf,
    name: String,
}

impl io::Write for Appender {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        todo!()
    }

    fn flush(&mut self) -> io::Result<()> {
        todo!()
    }
}

// Copied from `tracing-appender/src/rolling.rs`.
fn create_writer(directory: &str, filename: &str) -> io::Result<fs::File> {
    let path = Path::new(directory).join(filename);
    let mut open_options = fs::OpenOptions::new();
    open_options.append(true).create(true);

    let new_file = open_options.open(path.as_path());
    if new_file.is_err() {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
            return open_options.open(path);
        }
    }

    new_file
}
