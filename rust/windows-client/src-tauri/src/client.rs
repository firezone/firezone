use anyhow::Result;
use clap::Parser;
use cli::CliCommands as Cmd;
use std::{os::windows::process::CommandExt, process::Command};

mod cli;
mod debug_commands;
#[cfg(target_family = "windows")]
mod deep_link;
mod device_id;
#[cfg(target_family = "windows")]
mod elevation;
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
mod logging;
// Relies on some types from Tauri
#[cfg(target_os = "windows")]
mod settings;
mod wintun_install;

/// Prevents a problem where changing the args to `gui::run` breaks static analysis on non-Windows targets, where the gui is stubbed out
#[allow(dead_code)]
pub(crate) struct GuiParams {
    /// True if we should slow down I/O operations to test how the GUI handles slow I/O
    inject_faults: bool,
}

/// Newtype for our per-user directory in AppData, e.g.
/// `C:/Users/$USER/AppData/Local/dev.firezone.client`
pub(crate) struct AppLocalDataDir(std::path::PathBuf);

// Hides Powershell's console on Windows
// <https://stackoverflow.com/questions/59692146/is-it-possible-to-use-the-standard-library-to-spawn-a-process-without-showing-th#60958956>
const CREATE_NO_WINDOW: u32 = 0x08000000;

pub(crate) fn run() -> Result<()> {
    let cli = cli::Cli::parse();

    match cli.command {
        None => {
            if elevation::check()? {
                // We're already elevated, just run the GUI
                gui::run(GuiParams {
                    inject_faults: cli.inject_faults,
                })
            } else {
                // We're not elevated, ask Powershell to re-launch us, then exit
                let current_exe = tauri_utils::platform::current_exe()?;
                Command::new("powershell")
                    .creation_flags(CREATE_NO_WINDOW)
                    .arg("-Command")
                    .arg("Start-Process")
                    .arg("-FilePath")
                    .arg(current_exe)
                    .arg("-Verb")
                    .arg("RunAs")
                    .arg("-ArgumentList")
                    .arg("elevated")
                    .spawn()?;
                Ok(())
            }
        }
        Some(Cmd::Debug) => {
            println!("debug");
            Ok(())
        }
        Some(Cmd::DebugPipeServer) => debug_commands::pipe_server(),
        Some(Cmd::DebugToken) => debug_commands::token(),
        Some(Cmd::DebugWintun) => debug_commands::wintun(cli),
        // If we already tried to elevate ourselves, don't try again
        Some(Cmd::Elevated) => gui::run(GuiParams {
            inject_faults: cli.inject_faults,
        }),
        Some(Cmd::OpenDeepLink(deep_link)) => debug_commands::open_deep_link(&deep_link.url),
        Some(Cmd::RegisterDeepLink) => debug_commands::register_deep_link(),
    }
}
