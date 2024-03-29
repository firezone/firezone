use connlib_client_shared::file_logger;
use std::path::Path;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, Layer};

#[allow(clippy::print_stdout)]
fn main() {
    let log_dir = Path::new("./target");

    println!("Logging to {}", log_dir.canonicalize().unwrap().display());

    let (file_layer, _handle) = file_logger::layer(log_dir);

    tracing_subscriber::registry()
        .with(file_layer.with_filter(EnvFilter::new("info")))
        .init();

    tracing::info!("First log");
    tracing::info!("Second log");
    tracing::info!("Third log");
    tracing::info!("Fourth log");
}
