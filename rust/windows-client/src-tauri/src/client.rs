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
mod logging;
// Relies on some types from Tauri
#[cfg(target_os = "windows")]
mod settings;

/// Prevents a problem where changing the args to `gui::run` breaks static analysis on non-Windows targets, where the gui is stubbed out
#[allow(dead_code)]
pub(crate) struct GuiParams {
    /// True if we should slow down I/O operations to test how the GUI handles slow I/O
    inject_faults: bool,
}

/// Newtype for our per-user directory in AppData, e.g.
/// `C:/Users/$USER/AppData/Local/dev.firezone.client`
pub(crate) struct AppLocalDataDir(std::path::PathBuf);

pub(crate) fn run() -> Result<()> {
    // Special case for app link URIs
    if let Some(arg) = std::env::args().nth(1) {
        if let Ok(url) = url::Url::parse(&arg) {
            if url.scheme() == DEEP_LINK_SCHEME {
                return gui::run(GuiParams {
                    inject_faults: false,
                });
            }
        }
    }

    let cli = cli::Cli::parse();

    match cli.command {
        None => gui::run(GuiParams {
            inject_faults: cli.inject_faults,
        }),
        Some(Cmd::Debug) => {
            println!("debug");
            Ok(())
        }
        Some(Cmd::DebugResolvers) => debug_commands::resolvers(),
        Some(Cmd::DebugToken) => debug_commands::token(),
        Some(Cmd::DebugWintun) => debug_commands::wintun(cli),
    }
}

pub(crate) const DEEP_LINK_SCHEME: &str = "firezone-fd0020211111";
