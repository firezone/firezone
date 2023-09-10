//! Connlib File Logger
//!
//! This module implements a file-based logger for connlib using tracing-appender.
//!
//! The log files are rotated hourly and periodically synced to GCP object storage for debugging
//! by Firezone staff. This is done via a short-lived, signed URL that can be requested
//! by the Portal over an authenticated control plane connection via the `log_url` message.
//!
//! Log files older than 30 days are **not** uploaded. We intentionally don't delete log files
//! because they may be relevant for admins to debug issues that occurred an unknown time in the past.
//!
//! Since these will be leaving the user's device, these logs should contain *only*
//! the necessary debugging information, and **not** any sensitive information,
//! including but not limited to:
//! - WiFi SSIDs
//! - Location information
//! - Device names
//! - Device serials
//! - MAC addresses

use std::{fs, path::PathBuf};
use tracing::{level_filters::LevelFilter, Subscriber};
use tracing_subscriber::{EnvFilter, Layer};

const LOG_FILE_BASE_NAME: &str = "connlib.log";

pub fn layer<T>(log_dir: PathBuf) -> Result<Box<dyn Layer<T> + Send + Sync>, std::io::Error>
where
    T: Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    tracing::info!("Saving log files to: {}", log_dir.display());

    match fs::create_dir_all(&log_dir) {
        Ok(_) => {
            let (writer, _guard) = tracing_appender::non_blocking(
                tracing_appender::rolling::hourly(log_dir, LOG_FILE_BASE_NAME),
            );

            // Only log WARN and higher to disk by default
            let env_filter = EnvFilter::builder()
                .with_default_directive(LevelFilter::WARN.into())
                .from_env_lossy();

            // TODO: This could be improved with a GCP project ID
            let layer = tracing_stackdriver::layer()
                .with_writer(writer)
                .with_filter(env_filter)
                .boxed();

            Ok(layer)
        }
        Err(e) => Err(e),
    }
}
