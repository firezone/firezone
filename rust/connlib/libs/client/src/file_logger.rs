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

use std::path::Path;
use tracing::{level_filters::LevelFilter, Subscriber};
use tracing_subscriber::Layer;

const LOG_FILE_BASE_NAME: &str = "connlib.log";

/// Create a new file logger layer.
pub fn layer<T>(
    log_dir: &Path,
) -> (
    Box<dyn Layer<T> + Send + Sync + 'static>,
    tracing_appender::non_blocking::WorkerGuard,
    tracing_on_demand_rolling_appender::Handle,
)
where
    T: Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    #[cfg(debug_assertions)]
    let level = LevelFilter::DEBUG;

    #[cfg(not(debug_assertions))]
    let level = LevelFilter::WARN;

    let (appender, handle) = tracing_on_demand_rolling_appender::new(
        log_dir.to_path_buf(),
        LOG_FILE_BASE_NAME.to_owned(),
    );

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
