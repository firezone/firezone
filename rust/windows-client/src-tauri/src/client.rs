use anyhow::Result;
use clap::Parser;
use cli::CliCommands as Cmd;
use std::{os::windows::process::CommandExt, process::Command};

mod cli;
mod debug_commands;
mod deep_link;
mod device_id;
mod elevation;
mod gui;
mod logging;
mod resolvers;
mod settings;
mod wintun_install;

/// Prevents a problem where changing the args to `gui::run` breaks static analysis on non-Windows targets, where the gui is stubbed out
#[allow(dead_code)]
pub(crate) struct GuiParams {
    /// True if we were re-launched with elevated permissions. If the user launched us directly with elevated permissions, this is false.
    flag_elevated: bool,
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
                    flag_elevated: false,
                    inject_faults: cli.inject_faults,
                })
            } else {
                // We're not elevated, ask Powershell to re-launch us, then exit
                let current_exe = tauri_utils::platform::current_exe()?;
                if current_exe.display().to_string().contains('\"') {
                    anyhow::bail!("The exe path must not contain double quotes, it makes it hard to elevate with Powershell");
                }
                Command::new("powershell")
                    .creation_flags(CREATE_NO_WINDOW)
                    .arg("-Command")
                    .arg("Start-Process")
                    .arg("-FilePath")
                    .arg(format!(r#""{}""#, current_exe.display()))
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
        Some(Cmd::DebugResolvers) => debug_commands::resolvers(),
        Some(Cmd::DebugPipeServer) => debug_commands::pipe_server(),
        Some(Cmd::DebugToken) => debug_commands::token(),
        Some(Cmd::DebugWintun) => debug_commands::wintun(cli),
        // If we already tried to elevate ourselves, don't try again
        Some(Cmd::Elevated) => gui::run(GuiParams {
            flag_elevated: true,
            inject_faults: cli.inject_faults,
        }),
        Some(Cmd::OpenDeepLink(deep_link)) => debug_commands::open_deep_link(&deep_link.url),
        Some(Cmd::RegisterDeepLink) => debug_commands::register_deep_link(),
    }
}

#[cfg(test)]
mod tests {
    use anyhow::Result;

    #[test]
    fn exe_path() -> Result<()> {
        // e.g. `\\\\?\\C:\\cygwin64\\home\\User\\projects\\firezone\\rust\\target\\debug\\deps\\firezone_windows_client-5f44800b2dafef90.exe`
        let path = tauri_utils::platform::current_exe()?.display().to_string();
        assert!(path.contains("target"));
        assert!(!path.contains('\"'), "`{}`", path);
        Ok(())
    }
}
