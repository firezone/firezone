//! The Firezone GUI client for Windows

// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() -> anyhow::Result<()> {
    client::run()
}

#[cfg(target_family = "unix")]
mod client {
    pub(crate) fn run() -> anyhow::Result<()> {
        panic!("The Windows client does not compile on non-Windows platforms");
    }
}

#[cfg(target_os = "windows")]
mod client;
