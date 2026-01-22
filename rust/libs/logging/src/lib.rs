#![cfg_attr(test, allow(clippy::unwrap_used))]

pub mod cleanup;
pub mod file;
mod format;
#[macro_use]
mod unwrap_or;
mod ansi;
mod capturing_writer;
mod display_btree_set;
mod err_with_sources;
mod event_message_contains_filter;
pub mod windows_event_log;

use std::sync::Arc;

use anyhow::{Context, Result};
use event_message_contains_filter::EventMessageContains;
use sentry_tracing::EventFilter;
use telemetry::feature_flags;
use tracing::{Subscriber, subscriber::DefaultGuard};
use tracing_log::LogTracer;
use tracing_subscriber::{
    EnvFilter, Layer, Registry,
    filter::{FilterExt, ParseError, Targets},
    fmt,
    layer::SubscriberExt as _,
    registry::LookupSpan,
    reload,
    util::SubscriberInitExt,
};

pub use ansi::stdout_supports_ansi;
pub use capturing_writer::CapturingWriter;
pub use display_btree_set::DisplayBTreeSet;
pub use err_with_sources::{ErrorWithSources, err_with_src};
pub use format::Format;

/// Registers a global subscriber with stdout logging and `additional_layer`
pub fn setup_global_subscriber<L>(
    directives: String,
    additional_layer: L,
    stdout_json: bool,
) -> Result<FilterReloadHandle>
where
    L: Layer<Registry> + Send + Sync,
{
    if let Err(error) = output_vt100::try_init() {
        tracing::debug!("Failed to init terminal colors: {error}");
    }

    let (filter1, reload_handle1) =
        try_filter(&directives).context("Failed to parse directives")?;
    let (filter2, reload_handle2) =
        try_filter(&directives).context("Failed to parse directives")?;

    let subscriber = Registry::default()
        .with(additional_layer.with_filter(filter1))
        .with(sentry_layer())
        .with(match stdout_json {
            true => fmt::layer()
                .json()
                .flatten_event(true)
                .with_ansi(stdout_supports_ansi())
                .with_filter(filter2)
                .boxed(),
            false => fmt::layer()
                .with_ansi(stdout_supports_ansi())
                .event_format(Format::new())
                .with_filter(filter2)
                .boxed(),
        });
    init(subscriber)?;

    Ok(reload_handle1.merge(reload_handle2))
}

/// Sets up a bootstrap logger.
pub fn setup_bootstrap() -> Result<DefaultGuard> {
    let directives = std::env::var("RUST_LOG").unwrap_or_else(|_| "info".to_string());

    let (filter, _) = try_filter(&directives).context("failed to parse directives")?;
    let layer = tracing_subscriber::fmt::layer()
        .event_format(Format::new())
        .with_filter(filter);
    let subscriber = Registry::default().with(layer);

    Ok(tracing::dispatcher::set_default(&subscriber.into()))
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
    const IRRELEVANT_CRATES: &str = "netlink_proto=warn,os_info=warn,rustls=warn,opentelemetry_sdk=info,opentelemetry=info,hyper_util=info,h2=info,hickory_proto=info,hickory_resolver=info";

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
pub fn sentry_layer<S>() -> impl Layer<S> + Send + Sync
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    use tracing::Level;

    let wire_api_target = Targets::new().with_target("wire::api", tracing::Level::TRACE);

    sentry_tracing::layer()
        .event_filter(move |md| {
            let mut event_filter = match *md.level() {
                Level::ERROR | Level::WARN => EventFilter::Event | EventFilter::Breadcrumb,
                Level::INFO | Level::DEBUG => EventFilter::Breadcrumb,
                Level::TRACE => EventFilter::Ignore,
            };

            if wire_api_target.would_enable(md.target(), md.level()) {
                event_filter |= EventFilter::Breadcrumb;
            }

            if feature_flags::stream_logs(md) {
                event_filter |= EventFilter::Log
            }

            event_filter
        })
        .span_filter(|md| {
            matches!(
                *md.level(),
                Level::ERROR | Level::WARN | Level::INFO | Level::DEBUG
            )
        })
        .enable_span_attributes()
        .with_filter(parse_filter("trace").expect("static filter always parses"))
        .with_filter(EventMessageContains::all(
            Level::ERROR,
            &[
                "WinTun: Failed to create process: rundll32",
                r#"RemoveInstance "SWD\WINTUN\{E9245BC1-B8C1-44CA-AB1D-C6AAD4F13B9C}""#,
                "(Code 0x00000003)",
            ],
        ).not())
        .with_filter(EventMessageContains::all(
            Level::ERROR,
            &[
                r#"WinTun: Error executing worker process: "SWD\WINTUN\{E9245BC1-B8C1-44CA-AB1D-C6AAD4F13B9C}""#,
                "(Code 0x00000003)",
            ],
        ).not())
        .with_filter(EventMessageContains::all(
            Level::ERROR,
            &[
                "WinTun: Failed to remove adapter when closing",
                "(Code 0x00000003)",
            ],
        ).not())
        .with_filter(EventMessageContains::all(
            Level::ERROR,
            &[
                r#"WinTun: Failed to remove orphaned adapter "Firezone""#,
                "(Code 0x00000003)",
            ],
        ).not())
}
