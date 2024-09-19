//! The Firezone GUI client for Linux and Windows

// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod client;

fn main() -> anyhow::Result<()> {
    let _guard = sentry::init(("https://db4f1661daac806240fce8bcec36fa2a@o4507971108339712.ingest.us.sentry.io/4507980445908992", sentry::ClientOptions {
    release: sentry::release_name!(),
    ..Default::default()
    }));
    client::run()
}
