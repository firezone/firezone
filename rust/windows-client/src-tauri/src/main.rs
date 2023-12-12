//! The Firezone GUI client for Windows

// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use anyhow::Result;
use clap::Parser;
use cli::CliCommands as Cmd;

mod cli;
mod debug_commands;
mod device_id;
#[cfg(target_family = "unix")]
mod gui {
    use super::*;

    pub enum ControllerRequest {
        SignIn,
    }

    pub(crate) fn run(_: GuiParams) -> Result<()> {
        // The Ubuntu CI runner doesn't have gdk and some other Tauri deps installed, so it fails unless we stub out the GUI.
        panic!("The Tauri GUI isn't implemented for Linux.");
    }
}
#[cfg(target_os = "windows")]
mod gui;
mod local_webserver;
// Relies on some types from Tauri
#[cfg(target_os = "windows")]
mod settings;
#[cfg(target_os = "windows")]
mod wintun_install;

/// Prevents a problem where changing the args to `gui::run` breaks static analysis on non-Windows targets, where the gui is stubbed out
#[allow(dead_code)]
pub(crate) struct GuiParams {
    /// The URL of an incoming deep link from a web browser
    deep_link: Option<String>,
    /// True if we should slow down I/O operations to test how the GUI handles slow I/O
    inject_faults: bool,
}

fn main() -> Result<()> {
    // Special case for app link URIs
    if let Some(arg) = std::env::args().nth(1) {
        let scheme = format!("{DEEP_LINK_SCHEME}://");
        if arg.starts_with(&scheme) {
            return gui::run(GuiParams {
                deep_link: Some(arg),
                inject_faults: false,
            });
        }
    }

    let cli = cli::Cli::parse();

    match cli.command {
        None => gui::run(GuiParams {
            deep_link: None,
            inject_faults: cli.inject_faults,
        }),
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

pub(crate) const DEEP_LINK_SCHEME: &str = "firezone-fd0020211111";
