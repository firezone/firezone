use tracing::subscriber::DefaultGuard;
use tracing_log::LogTracer;
use tracing_subscriber::{
    fmt, layer::SubscriberExt as _, util::SubscriberInitExt, EnvFilter, Layer, Registry,
};

pub fn setup_global_subscriber<L>(additional_layer: L)
where
    L: Layer<Registry> + Send + Sync,
{
    let subscriber = Registry::default()
        .with(additional_layer)
        .with(fmt::layer())
        .with(EnvFilter::from_default_env());
    tracing::subscriber::set_global_default(subscriber).expect("Could not set global default");
    LogTracer::init().unwrap();
}

/// Initialises a logger to be used in tests.
pub fn test(directives: &str) -> DefaultGuard {
    tracing_subscriber::fmt()
        .with_test_writer()
        .with_env_filter(directives)
        .set_default()
}
