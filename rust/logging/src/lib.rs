mod dyn_err;
pub mod file;
mod format;
#[macro_use]
mod unwrap_or;

use sentry_tracing::EventFilter;
use tracing::{subscriber::DefaultGuard, Subscriber};
use tracing_log::LogTracer;
use tracing_subscriber::{
    filter::ParseError, fmt, layer::SubscriberExt as _, registry::LookupSpan,
    util::SubscriberInitExt, EnvFilter, Layer, Registry,
};

pub use dyn_err::{anyhow_dyn_err, std_dyn_err};
pub use format::Format;

/// Registers a global subscriber with stdout logging and `additional_layer`
pub fn setup_global_subscriber<L>(additional_layer: L)
where
    L: Layer<Registry> + Send + Sync,
{
    let directives = std::env::var("RUST_LOG").unwrap_or_default();

    let subscriber = Registry::default()
        .with(additional_layer.with_filter(filter(&directives)))
        .with(sentry_layer()) // Sentry layer has its own event filtering mechanism.
        .with(
            fmt::layer()
                .event_format(Format::new())
                .with_filter(filter(&directives)),
        );
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

/// Constructs a [`tracing::Layer`](Layer) that captures events and spans and reports them to Sentry.
///
/// ## Events
///
/// - error and warn events are reported as sentry exceptions
/// - info and debug events are captured as breadcrumbs (and submitted together with warns & errors)
///
/// ## Telemetry events
///
/// This layer configuration supports a special `telemetry` event.
/// Telemetry events are events logged on the `TRACE` level for the `telemetry` target.
/// They are sampled at a rate of 1%.
/// The idea here is that some events logged via `tracing` should not necessarily end up in the users log file.
/// Yet, if they happen a lot, we still want to know about them.
/// Coupling the `telemetry` target to the `TRACE` level pretty much prevents these events from ever showing up in log files.
/// By sampling them, we prevent flooding Sentry with lots of these logs.
///
/// ## Telemetry spans
///
/// Only spans with the `telemetry` target on level `TRACE` will be submitted to Sentry.
/// They are subject to the sampling rate defined in the Sentry client configuration.
pub fn sentry_layer<S>() -> sentry_tracing::SentryLayer<S>
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    sentry_tracing::layer()
        .event_filter(move |md| match *md.level() {
            tracing::Level::ERROR | tracing::Level::WARN => EventFilter::Exception,
            tracing::Level::INFO | tracing::Level::DEBUG => EventFilter::Breadcrumb,
            tracing::Level::TRACE if md.target() == "telemetry" => {
                // rand::random generates floats in the range of [0, 1).
                if rand::random::<f32>() < 0.01 {
                    EventFilter::Event
                } else {
                    EventFilter::Ignore
                }
            }
            _ => EventFilter::Ignore,
        })
        .span_filter(|md| *md.level() == tracing::Level::TRACE && md.target() == "telemetry")
        .enable_span_attributes()
}
