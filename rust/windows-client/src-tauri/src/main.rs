//! The Firezone GUI client for Windows

// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use crate::prelude::*;
use clap::Parser;

mod cli;
mod debug_commands;
#[cfg(target_os = "linux")]
mod gui {
    use crate::prelude::*;
    pub fn main(_: Option<CommonArgs>, _: Option<String>) -> Result<()> {
        // The Ubuntu CI runner doesn't have gdk and some other Tauri deps installed, so it fails unless we stub out the GUI.
        panic!("The Tauri GUI isn't implemented for Linux.");
    }
}
#[cfg(target_os = "windows")]
mod gui;
mod prelude;

fn main() -> Result<()> {
    use cli::CliCommands as Cmd;

    change_to_well_known_dir()?;

    // Special case for app link URIs
    if let Some(arg) = std::env::args().nth(1) {
        if arg.starts_with("firezone://") {
            return gui::main(None, Some(arg));
        }
    }

    let cli = cli::Cli::parse();

    match cli.command {
        None => gui::main(None, None),
        Some(Cmd::Tauri { common }) => gui::main(common, None),
        Some(Cmd::Debug) => {
            println!("debug");
            Ok(())
        }
        Some(Cmd::DebugConnlib { common }) => debug_commands::connlib(common),
        Some(Cmd::DebugCredentials) => debug_commands::credentials(),
        Some(Cmd::DebugDeviceId) => debug_commands::device_id(),
        Some(Cmd::DebugWintun) => debug_commands::wintun(cli),
    }
}

/// Change dir to the app's local data dir. This prevents issues with the logger trying to write to C:\Windows\System32 when Firefox / Chrome launches us in that dir.

fn change_to_well_known_dir() -> Result<()> {
    let project_dirs = cli::get_project_dirs()?;
    let working_dir = project_dirs.data_local_dir();
    std::fs::create_dir_all(working_dir)?;
    std::env::set_current_dir(working_dir)?;
    Ok(())
}
