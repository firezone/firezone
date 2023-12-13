//! Separate module to contain all the `use` statements for setting up logging

use anyhow::Result;
use connlib_client_shared::file_logger;
use std::{path::Path, str::FromStr};
use tracing::subscriber::set_global_default;
use tracing_log::LogTracer;
use tracing_subscriber::{fmt, layer::SubscriberExt, reload, EnvFilter, Layer, Registry};

pub(crate) struct Handles {
    pub logger: file_logger::Handle,
    pub _reloader: reload::Handle<EnvFilter, Registry>,
}

/// Set up logs for the first time.
/// Must be called inside Tauri's `setup` callback, after the app has changed directory
pub(crate) fn setup(log_filter: &str) -> Result<Handles> {
    let (layer, logger) = file_logger::layer(Path::new("logs"));
    let filter = EnvFilter::from_str(log_filter)?;
    let (filter, reloader) = reload::Layer::new(filter);
    let subscriber = Registry::default()
        .with(layer.with_filter(filter))
        .with(fmt::layer().with_filter(EnvFilter::from_str(log_filter)?));
    set_global_default(subscriber)?;
    LogTracer::init()?;
    Ok(Handles {
        logger,
        _reloader: reloader,
    })
}
