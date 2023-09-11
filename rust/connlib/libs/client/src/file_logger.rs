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

use std::path::PathBuf;
use tracing::{level_filters::LevelFilter, Subscriber};
use tracing_subscriber::Layer;

const LOG_FILE_BASE_NAME: &str = "connlib.log";

/// Create a new file logger layer.
pub fn layer<T>(
    log_dir: PathBuf,
) -> (
    Box<dyn Layer<T> + Send + Sync + 'static>,
    tracing_appender::non_blocking::WorkerGuard,
)
where
    T: Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    tracing::info!("Saving log files to: {}", log_dir.display());

    let (writer, guard) = tracing_appender::non_blocking(tracing_appender::rolling::hourly(
        log_dir,
        LOG_FILE_BASE_NAME,
    ));

    let layer = tracing_stackdriver::layer()
        .with_writer(writer)
        .with_filter(if cfg!(debug_assertions) {
            LevelFilter::DEBUG
        } else {
            LevelFilter::WARN
        })
        .boxed();

    // Return the guard so that the caller maintains a handle to it. Otherwise,
    // we have to wait for tracing_appender to flush the logs before exiting.
    // See https://docs.rs/tracing-appender/latest/tracing_appender/non_blocking/struct.WorkerGuard.html
    (layer, guard)
}
