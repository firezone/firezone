use firezone_client_connlib::file_logger;
use std::path::Path;
use std::time::Duration;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;

fn main() {
    let log_dir = Path::new("./target");

    println!("Logging to {}", log_dir.canonicalize().unwrap().display());

    let (file_layer, _guard, handle) = file_logger::layer(log_dir, "info");

    tracing_subscriber::registry().with(file_layer).init();

    tracing::info!("First log");
    tracing::info!("Second log");

    std::thread::sleep(Duration::from_secs(1)); // Make sure we don't use the same filename.

    handle.roll_to_new_file().unwrap().unwrap();

    tracing::info!("Third log");
    tracing::info!("Fourth log");
}
