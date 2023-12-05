//! The Firezone GUI client for Windows

// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use anyhow::Result;
use clap::Parser;
use cli::CliCommands as Cmd;

mod cli;
mod debug_commands;
mod device_id;
#[cfg(target_os = "linux")]
mod gui {
    use super::*;

    pub enum ControllerRequest {
        SignIn,
    }

    pub fn run(_: Option<String>) -> Result<()> {
        // The Ubuntu CI runner doesn't have gdk and some other Tauri deps installed, so it fails unless we stub out the GUI.
        panic!("The Tauri GUI isn't implemented for Linux.");
    }
}
#[cfg(target_os = "windows")]
mod gui;
mod local_webserver;

fn main() -> Result<()> {
    // Special case for app link URIs
    if let Some(arg) = std::env::args().nth(1) {
        if arg.starts_with("firezone://") {
            return gui::run(Some(arg));
        }
    }

    let cli = cli::Cli::parse();

    match cli.command {
        None => gui::run(None),
        Some(Cmd::Debug) => {
            println!("debug");
            Ok(())
        }
        Some(Cmd::DebugConnlib { common }) => debug_commands::connlib(common),
        Some(Cmd::DebugDeviceId) => debug_commands::device_id(),
        Some(Cmd::DebugToken) => debug_commands::token(),
        Some(Cmd::DebugWintun) => debug_commands::wintun(cli),
    }
}
