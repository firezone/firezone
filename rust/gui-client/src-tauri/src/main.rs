//! The Firezone GUI client for Linux and Windows

// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Arc;

mod client;

fn main() -> anyhow::Result<()> {
    // Sentry docs say this does not need to be protected:
    // > DSNs are safe to keep public because they only allow submission of new events and related event data; they do not allow read access to any information.
    // <https://docs.sentry.io/concepts/key-terms/dsn-explainer/#dsn-utilization>
    let sentry_guard = sentry::init(("https://db4f1661daac806240fce8bcec36fa2a@o4507971108339712.ingest.us.sentry.io/4507980445908992", sentry::ClientOptions {
    release: sentry::release_name!(),
    ..Default::default()
    }));
    sentry::start_session();
    // Use an `Arc` here so that the GUI can flush `sentry` when it's closing up
    // even though the borrowing is complex
    let sentry_guard = Arc::new(sentry_guard);
    client::run(Arc::clone(&sentry_guard))
}
