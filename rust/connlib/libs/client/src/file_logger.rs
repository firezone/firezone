//! Connlib File Logger
//!
//! This module implements a file-based logger for connlib using tracing-subscriber and
//! tracing-appender.
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

const LOG_FILE_BASE_NAME: &str = "connlib.log";

use std::path::Path;

pub struct FileLogger {
    pub writer: tracing_appender::non_blocking::NonBlocking,
}

impl FileLogger {
    pub fn init(log_dir: String) -> Self {
        tracing::info!("Saving log files to: {log_dir}");

        match Path::new(&log_dir).exists() {
            true => (),
            false => {
                tracing::warn!("specified log_dir {log_dir} does not exist! Creating...");

                match std::fs::create_dir_all(&log_dir) {
                    Ok(_) => (),
                    Err(e) => tracing::error!("Failed to create log directory {log_dir}: {e}"),
                }
            }
        }

        let (writer, _guard) = tracing_appender::non_blocking(tracing_appender::rolling::hourly(
            log_dir,
            LOG_FILE_BASE_NAME,
        ));

        Self { writer }
    }
}
