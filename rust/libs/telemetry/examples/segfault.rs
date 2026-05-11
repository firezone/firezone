//! Reproducer that exercises the native crash handler end-to-end.
//!
//! Installs the crash handler against the GUI Sentry project (env=staging in
//! debug builds) and then deliberately segfaults the parent process. The
//! watcher subprocess should capture a minidump and upload it to Sentry.
//!
//! Run with:
//!   cargo run -p telemetry --example segfault

fn main() {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,sentry=trace".into()),
        )
        .init();

    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("install default crypto provider");

    let crash_reporter = telemetry::install_crash_handler(
        telemetry::GUI_DSN,
        concat!("crash-test@", env!("CARGO_PKG_VERSION")),
    );
    tracing::info!(
        installed = crash_reporter.is_some(),
        "crash handler initialised"
    );

    tracing::info!(pid = std::process::id(), "sleeping 3s before segfault");
    std::thread::sleep(std::time::Duration::from_secs(3));

    tracing::info!("dereferencing null pointer");
    unsafe {
        std::ptr::null_mut::<u8>().write(0);
    }
}
