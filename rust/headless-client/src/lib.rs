//! A library for the privileged tunnel process for a Linux Firezone Client
//!
//! This is built both standalone and as part of the GUI package. Building it
//! standalone is faster and skips all the GUI dependencies. We can use that build for
//! CLI use cases.
//!
//! Building it as a binary within the `gui-client` package allows the
//! Tauri deb bundler to pick it up easily.
//! Otherwise we would just make it a normal binary crate.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{Context as _, Result};
use firezone_logging::FilterReloadHandle;
use tracing_subscriber::{EnvFilter, Layer as _, Registry, fmt, layer::SubscriberExt as _};

mod clear_logs;
mod ipc_service;

pub use clear_logs::clear_logs;
pub use ipc_service::{
    ClientMsg as IpcClientMsg, Error as IpcServiceError, ServerMsg as IpcServerMsg, ipc,
    run_only_ipc_service,
};

/// Sets up logging for stdout only, with INFO level by default
pub fn setup_stdout_logging() -> Result<FilterReloadHandle> {
    let directives = get_log_filter().context("Can't read log filter")?;
    let (filter, reloader) = firezone_logging::try_filter(&directives)?;
    let layer = fmt::layer()
        .event_format(firezone_logging::Format::new())
        .with_filter(filter);
    let subscriber = Registry::default().with(layer);
    firezone_logging::init(subscriber)?;

    Ok(reloader)
}

/// Reads the log filter for the IPC service or for debug commands
///
/// e.g. `info`
///
/// Reads from:
/// 1. `RUST_LOG` env var
/// 2. `known_dirs::ipc_log_filter()` file
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

    if let Ok(filter) = std::fs::read_to_string(firezone_bin_shared::known_dirs::ipc_log_filter()?)
        .map(|s| s.trim().to_string())
    {
        return Ok(filter);
    }

    Ok(DEFAULT_LOG_FILTER.to_string())
}
