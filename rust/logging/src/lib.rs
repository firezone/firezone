#![cfg_attr(test, allow(clippy::unwrap_used))]

pub mod file;
mod format;
#[macro_use]
mod unwrap_or;
mod ansi;
mod err_with_sources;

use std::sync::Arc;

use anyhow::{Context, Result};
use sentry_tracing::EventFilter;
use tracing::{Subscriber, subscriber::DefaultGuard};
use tracing_log::LogTracer;
use tracing_subscriber::{
    EnvFilter, Layer, Registry, filter::ParseError, fmt, layer::SubscriberExt as _,
    registry::LookupSpan, reload, util::SubscriberInitExt,
};

pub use ansi::stdout_supports_ansi;
pub use err_with_sources::{ErrorWithSources, err_with_src};
pub use format::Format;

/// Registers a global subscriber with stdout logging and `additional_layer`
pub fn setup_global_subscriber<L>(additional_layer: L) -> Result<FilterReloadHandle>
where
    L: Layer<Registry> + Send + Sync,
{
    if let Err(error) = output_vt100::try_init() {
        tracing::debug!("Failed to init terminal colors: {error}");
    }

    let directives = std::env::var("RUST_LOG").unwrap_or_default();

    let (filter1, reload_handle1) =
        try_filter(&directives).context("Failed to parse directives")?;
    let (filter2, reload_handle2) =
        try_filter(&directives).context("Failed to parse directives")?;

    let subscriber = Registry::default()
        .with(additional_layer.with_filter(filter1))
        .with(sentry_layer())
        .with(
            fmt::layer()
                .with_ansi(stdout_supports_ansi())
                .event_format(Format::new())
                .with_filter(filter2),
        );
    init(subscriber)?;

    Ok(reload_handle1.merge(reload_handle2))
}

#[expect(
    clippy::disallowed_methods,
    reason = "This is the alternative function."
)]
pub fn init(subscriber: impl Subscriber + Send + Sync + 'static) -> Result<()> {
    tracing::subscriber::set_global_default(subscriber).context("Could not set global default")?;
    LogTracer::init().context("Failed to init LogTracer")?;

    Ok(())
}

/// Constructs an opinionated [`EnvFilter`] with some crates already silenced.
pub fn try_filter<S>(
    directives: &str,
) -> Result<(reload::Layer<EnvFilter, S>, FilterReloadHandle), ParseError>
where
    S: 'static,
{
    let env_filter = parse_filter(directives)?;

    let (layer, reload_handle) = reload::Layer::new(env_filter);
    let handle = FilterReloadHandle {
        inner: Arc::new(reload_handle),
    };

    Ok((layer, handle))
}

fn parse_filter(directives: &str) -> Result<EnvFilter, ParseError> {
    /// A filter directive that silences noisy crates.
    ///
    /// For debugging, it is useful to set a catch-all log like `debug`.
    /// This obviously creates a lot of logs from all kinds of crates.
    /// For our usecase, logs from `netlink_proto` and other crates are very likely not what you want to see.
    ///
    /// By prepending this directive to the active log filter, a simple directive like `debug` actually produces useful logs.
    /// If necessary, you can still activate logs from these crates by restating them in your directive with a lower filter, i.e. `netlink_proto=debug`.
    const IRRELEVANT_CRATES: &str = "netlink_proto=warn,os_info=warn,rustls=warn";

    let env_filter = if directives.is_empty() {
        EnvFilter::try_new(IRRELEVANT_CRATES)?
    } else {
        EnvFilter::try_new(format!("{IRRELEVANT_CRATES},{directives}"))?
    };

    Ok(env_filter)
}

pub struct FilterReloadHandle {
    inner: Arc<dyn Reload + Send + Sync>,
}

impl std::fmt::Debug for FilterReloadHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("FilterReloadHandle").finish_non_exhaustive()
    }
}

impl FilterReloadHandle {
    pub fn reload(&self, new_filter: &str) -> Result<()> {
        self.inner.reload(new_filter)?;

        Ok(())
    }

    pub fn merge(self, other: FilterReloadHandle) -> Self {
        Self {
            inner: Arc::new((self, other)),
        }
    }
}

trait Reload {
    fn reload(&self, new_filter: &str) -> Result<()>;
}

impl<S> Reload for tracing_subscriber::reload::Handle<EnvFilter, S>
where
    S: 'static,
{
    fn reload(&self, new_filter: &str) -> Result<()> {
        let filter = parse_filter(new_filter).context("Failed to parse new filter")?;

        self.reload(filter).context("Failed to reload filter")?;

        Ok(())
    }
}

impl Reload for (FilterReloadHandle, FilterReloadHandle) {
    fn reload(&self, new_filter: &str) -> Result<()> {
        let (a, b) = self;

        a.reload(new_filter)?;
        b.reload(new_filter)?;

        Ok(())
    }
}

/// Initialises a logger to be used in tests.
pub fn test(directives: &str) -> DefaultGuard {
    tracing_subscriber::fmt()
        .with_test_writer()
        .with_env_filter(directives)
        .set_default()
}

pub fn test_global(directives: &str) {
    init(
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
    use tracing::Level;

    sentry_tracing::layer()
        .event_filter(move |md| match *md.level() {
            Level::ERROR | Level::WARN => EventFilter::Exception,
            Level::INFO | Level::DEBUG => EventFilter::Breadcrumb,
            Level::TRACE if md.target() == TELEMETRY_TARGET => EventFilter::Event,
            _ => EventFilter::Ignore,
        })
        .span_filter(|md| {
            matches!(
                *md.level(),
                Level::ERROR | Level::WARN | Level::INFO | Level::DEBUG
            )
        })
        .enable_span_attributes()
        .with_filter(parse_filter("trace").expect("static filter always parses"))
    // Filter out noisy crates but pass all events otherwise.
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
