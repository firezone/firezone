use sentry_tracing::EventFilter;
use tracing::Subscriber;
use tracing_subscriber::registry::LookupSpan;

pub fn sentry_layer<S>() -> sentry_tracing::SentryLayer<S>
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    sentry_tracing::layer()
        .event_filter(|md| match *md.level() {
            tracing::Level::ERROR => EventFilter::Exception,
            tracing::Level::WARN => EventFilter::Event,
            tracing::Level::INFO => EventFilter::Breadcrumb,
            _ => EventFilter::Ignore,
        })
        .enable_span_attributes()
}
