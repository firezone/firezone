#![cfg_attr(test, allow(clippy::unwrap_used))]

mod dyn_err;
pub mod file;
mod format;
#[macro_use]
mod unwrap_or;
mod err_with_sources;

use anyhow::{Context, Result};
use sentry_tracing::EventFilter;
use tracing::{subscriber::DefaultGuard, Subscriber};
use tracing_log::LogTracer;
use tracing_subscriber::{
    filter::ParseError, fmt, layer::SubscriberExt as _, registry::LookupSpan,
    util::SubscriberInitExt, EnvFilter, Layer, Registry,
};

pub use dyn_err::{anyhow_dyn_err, std_dyn_err};
pub use err_with_sources::{err_with_sources, ErrorWithSources};
pub use format::Format;

/// Registers a global subscriber with stdout logging and `additional_layer`
pub fn setup_global_subscriber<L>(additional_layer: L) -> Result<()>
where
    L: Layer<Registry> + Send + Sync,
{
    let directives = std::env::var("RUST_LOG").unwrap_or_default();

    let subscriber = Registry::default()
        .with(
            additional_layer
                .with_filter(try_filter(&directives).context("Failed to parse directives")?),
        )
        .with(sentry_layer())
        .with(
            fmt::layer()
                .event_format(Format::new())
                .with_filter(try_filter(&directives).context("Failed to parse directives")?),
        );
    tracing::subscriber::set_global_default(subscriber).context("Could not set global default")?;
    LogTracer::init().context("Failed to init LogTracer")?;

    Ok(())
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

    if directives.is_empty() {
        return EnvFilter::try_new(IRRELEVANT_CRATES);
    }

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
/// These events SHOULD be created using [`telemetry_event`] to ensure that they are sampled correctly.
/// The idea here is that some events logged via `tracing` should not necessarily end up in the users log file.
/// Yet, if they happen a lot, we still want to know about them.
/// Coupling the `telemetry` target to the `TRACE` level pretty much prevents these events from ever showing up in log files.
/// By sampling them, we prevent flooding Sentry with lots of these logs.
///
/// ## Telemetry spans
///
/// Only spans with the `telemetry` target on level `TRACE` will be submitted to Sentry.
/// Similar to telemetry events, these should be created with [`telemetry_span`] to ensure they are sampled correctly.
pub fn sentry_layer<S>() -> impl Layer<S> + Send + Sync
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    const IGNORED_TARGETS: &[IgnoredEvent] = &[IgnoredEvent::warn(
        "tao::platform_impl::platform::event_loop::runner",
    )];

    sentry_tracing::layer()
        .event_filter(move |md| {
            let level = *md.level();

            if IGNORED_TARGETS.contains(&IgnoredEvent::new(*md.level(), md.target())) {
                return EventFilter::Ignore;
            }

            match level {
                tracing::Level::ERROR | tracing::Level::WARN => EventFilter::Exception,
                tracing::Level::INFO | tracing::Level::DEBUG => EventFilter::Breadcrumb,
                tracing::Level::TRACE if md.target() == TELEMETRY_TARGET => EventFilter::Event,
                _ => EventFilter::Ignore,
            }
        })
        .span_filter(|md| *md.level() == tracing::Level::TRACE && md.target() == TELEMETRY_TARGET)
        .enable_span_attributes()
        .with_filter(try_filter("trace").expect("static filter always parses")) // Filter out noisy crates but pass all events otherwise.
}

#[doc(hidden)]
pub const TELEMETRY_TARGET: &str = "telemetry";
#[doc(hidden)]
pub const TELEMETRY_SAMPLE_RATE: f32 = 0.01;

/// Creates a `telemetry` span that will be active until dropped.
///
/// In order to save CPU power, `telemetry` spans are sampled at a rate of 1% at creation time.
#[macro_export]
macro_rules! telemetry_span {
    ($($arg:tt)*) => {
        if $crate::__export::rand::random::<f32>() < $crate::TELEMETRY_SAMPLE_RATE {
            $crate::__export::tracing::trace_span!(target: $crate::TELEMETRY_TARGET, $($arg)*)
        } else {
            $crate::__export::tracing::Span::none()
        }
    };
}

/// Creates a `telemetry` event.
///
/// In order to save CPU power, `telemetry` events are sampled at a rate of 1% at creation time.
/// In addition, all telemetry events are logged at the `DEBUG` level.
#[macro_export]
macro_rules! telemetry_event {
    ($($arg:tt)*) => {
        if $crate::__export::rand::random::<f32>() < $crate::TELEMETRY_SAMPLE_RATE {
            $crate::__export::tracing::trace!(target: $crate::TELEMETRY_TARGET, $($arg)*);
        }

        $crate::__export::tracing::debug!($($arg)*);
    };
}

#[doc(hidden)]
pub mod __export {
    pub use rand;
    pub use tracing;
}

#[derive(Debug, PartialEq)]
struct IgnoredEvent<'a> {
    level: tracing::Level,
    target: &'a str,
}

impl<'a> IgnoredEvent<'a> {
    fn new(level: tracing::Level, target: &'a str) -> Self {
        Self { level, target }
    }

    const fn warn(target: &'static str) -> Self {
        Self {
            target,
            level: tracing::Level::WARN,
        }
    }
}
