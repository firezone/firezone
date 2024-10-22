mod dyn_err;
pub mod file;
mod format;
mod log_unwrap;

use tracing::subscriber::DefaultGuard;
use tracing_log::LogTracer;
use tracing_subscriber::{
    filter::ParseError, fmt, layer::SubscriberExt as _, util::SubscriberInitExt, EnvFilter, Layer,
    Registry,
};

pub use dyn_err::{anyhow_dyn_err, std_dyn_err};
pub use format::Format;
pub use log_unwrap::LogUnwrap;

/// Registers a global subscriber with stdout logging and `additional_layer`
pub fn setup_global_subscriber<L>(additional_layer: L)
where
    L: Layer<Registry> + Send + Sync,
{
    let directives = std::env::var("RUST_LOG").unwrap_or_default();

    let subscriber = Registry::default()
        .with(additional_layer)
        .with(fmt::layer().event_format(Format::new()))
        .with(filter(&directives));
    tracing::subscriber::set_global_default(subscriber).expect("Could not set global default");
    LogTracer::init().unwrap();
}

/// Constructs an opinionated [`EnvFilter`] with some crates already silenced.
pub fn filter(directives: &str) -> EnvFilter {
    try_filter(directives).unwrap()
}

/// Constructs an opinionated [`EnvFilter`] with some crates already silenced.
pub fn try_filter(directives: &str) -> Result<EnvFilter, ParseError> {
    /// A filter directive that silences noisy crates.
    ///
    /// For debugging, it is useful to set a catch-all log like `debug`.
    /// This obviously creates a lot of logs from all kinds of crates.
    /// For our usecase, logs from `netlink_proto` and other crates are very likely not what you want to see.
    ///
    /// By prepending this directive to the active log filter, a simple directive like `debug` actually produces useful logs.
    /// If necessary, you can still activate logs from these crates by restating them in your directive with a lower filter, i.e. `netlink_proto=debug`.
    const IRRELEVANT_CRATES: &str = "netlink_proto=warn,os_info=warn,rustls=warn";

    EnvFilter::try_new(format!("{IRRELEVANT_CRATES},{directives}"))
}

/// Initialises a logger to be used in tests.
pub fn test(directives: &str) -> DefaultGuard {
    tracing_subscriber::fmt()
        .with_test_writer()
        .with_env_filter(directives)
        .set_default()
}

pub fn test_global(directives: &str) {
    tracing::subscriber::set_global_default(
        tracing_subscriber::fmt()
            .with_test_writer()
            .with_env_filter(directives)
            .finish(),
    )
    .ok();
}
