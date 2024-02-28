//! The Firezone GUI client for Windows

// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() -> anyhow::Result<()> {
    client::run()
}

#[cfg(target_os = "linux")]
mod client;

#[cfg(target_os = "macos")]
mod client {
    pub(crate) fn run() -> anyhow::Result<()> {
        println!("The GUI client does not compile on macOS yet");
        Ok(())
    }
}

#[cfg(target_os = "windows")]
mod client;
