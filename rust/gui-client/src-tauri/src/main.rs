//! The Firezone GUI client for Windows

// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() -> anyhow::Result<()> {
    client::run()
}

// TODO: This is left over from when the GUI client didn't build for Linux.
// Refactor it out some day.
mod client;
