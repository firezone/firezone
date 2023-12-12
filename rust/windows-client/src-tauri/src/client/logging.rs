//! Separate module to contain all the `use` statements for setting up logging

use anyhow::Result;
use connlib_client_shared::file_logger;
use std::{path::Path, str::FromStr};
use tracing::subscriber::set_global_default;
use tracing_log::LogTracer;
use tracing_subscriber::{fmt, layer::SubscriberExt, EnvFilter, Layer, Registry};

/// Set up logs for the first time.
/// Must be called inside Tauri's `setup` callback, after the app has changed directory
pub(crate) fn setup(log_filter: &str) -> Result<file_logger::Handle> {
    let (layer, logger) = file_logger::layer(Path::new("logs"));
    let subscriber = Registry::default()
        .with(layer.with_filter(EnvFilter::from_str(log_filter)?))
        .with(fmt::layer().with_filter(EnvFilter::from_str(log_filter)?));
    set_global_default(subscriber)?;
    LogTracer::init()?;
    Ok(logger)
}
