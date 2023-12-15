use anyhow::Result;
use clap::Parser;
use cli::CliCommands as Cmd;

mod cli;
mod debug_commands;
mod deep_link;
mod device_id;
mod gui;
mod logging;
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
    let cli = cli::Cli::parse();

    match cli.command {
        None => gui::run(GuiParams {
            inject_faults: cli.inject_faults,
        }),
        Some(Cmd::Debug) => {
            println!("debug");
            Ok(())
        }
        Some(Cmd::DebugPipeServer) => debug_commands::pipe_server(),
        Some(Cmd::DebugToken) => debug_commands::token(),
        Some(Cmd::DebugWintun) => debug_commands::wintun(cli),
        Some(Cmd::OpenDeepLink(deep_link)) => debug_commands::open_deep_link(&deep_link.url),
        Some(Cmd::RegisterDeepLink) => debug_commands::register_deep_link(),
    }
}
