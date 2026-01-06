use anyhow::Result;
use tracing::span::Attributes;
use tracing::{Event, Id, Subscriber};
use tracing_subscriber::layer::Context;
use tracing_subscriber::registry::LookupSpan;

pub fn layer(source: &str) -> Result<Layer> {
    Layer::new(source)
}

/// A tracing layer that writes events to the Windows Event Log.
///
/// On non-Windows platforms, this does nothing.
pub struct Layer {}

impl Layer {
    #[expect(clippy::unnecessary_wraps, reason = "Fallible on Windows.")]
    fn new(_: &str) -> Result<Self> {
        Ok(Self {})
    }
}

impl<S> tracing_subscriber::Layer<S> for Layer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_new_span(&self, _: &Attributes<'_>, _: &Id, _: Context<'_, S>) {}

    fn on_record(&self, _: &Id, _: &tracing::span::Record<'_>, _: Context<'_, S>) {}

    fn on_event(&self, _: &Event<'_>, _: Context<'_, S>) {}
}
