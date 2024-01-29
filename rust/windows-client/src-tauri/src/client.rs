use anyhow::Result;
use clap::{Args, Parser};
use std::{os::windows::process::CommandExt, path::PathBuf, process::Command};

mod about;
mod auth;
mod crash_handling;
mod debug_commands;
mod deep_link;
mod device_id;
mod elevation;
mod gui;
mod ipc;
mod logging;
mod network_changes;
mod resolvers;
mod settings;
mod wintun_install;

/// Output of `git describe` at compile time
/// e.g. `1.0.0-pre.4-20-ged5437c88-modified` where:
///
/// * `1.0.0-pre.4` is the most recent ancestor tag
/// * `20` is the number of commits since then
/// * `g` doesn't mean anything
/// * `ed5437c88` is the Git commit hash
/// * `-modified` is present if the working dir has any changes from that commit number
pub const GIT_VERSION: &str =
    git_version::git_version!(args = ["--always", "--dirty=-modified", "--tags"]);

/// GuiParams prevents a problem where changing the args to `gui::run` breaks static analysis on non-Windows targets, where the gui is stubbed out
#[allow(dead_code)]
pub(crate) struct GuiParams {
    /// If true, purposely crash the program to test the crash handler
    crash_on_purpose: bool,
    /// If true, we were re-launched with elevated permissions. If the user launched us directly with elevated permissions, this is false.
    flag_elevated: bool,
    /// If true, slow down I/O operations to test how the GUI handles slow I/O
    inject_faults: bool,
}

// Hides Powershell's console on Windows
// <https://stackoverflow.com/questions/59692146/is-it-possible-to-use-the-standard-library-to-spawn-a-process-without-showing-th#60958956>
const CREATE_NO_WINDOW: u32 = 0x08000000;

/// The program's entry point, equivalent to `main`
///
/// When a user runs the Windows client normally without admin permissions, this will happen:
///
/// 1. The exe runs with ``, blank arguments
/// 2. We call `elevation::check` and find out we don't have permission to open a wintun adapter
/// 3. We spawn powershell's `Start-Process` cmdlet with `RunAs` to launch our `elevated` subcommand with admin permissions
/// 4. The original un-elevated process from Step 1 exits
/// 5. The exe runs with `elevated`, which won't recursively try to elevate itself if elevation failed
/// 6. The elevated process from Step 5 enters the GUI module and spawns a new process for crash handling
/// 7. That crash handler process starts with `crash-handler-server`. Instead of running the GUI, it enters the `crash_handling` module and becomes a crash server.
/// 8. The GUI process from Step 6 connects to the crash server as a client
/// 9. The GUI process registers itself as a named pipe server for deep links
/// 10. The GUI process registers the exe to receive deep links.
/// 11. When a web browser gets a deep link for authentication, Windows calls the exe with `open-deep-link` and the URL. This process connects to the pipe server inside the GUI process (Step 5), sends the URL to the GUI, then exits.
/// 12. The GUI process (Step 5) receives the deep link URL.
/// 13. (TBD - connlib may run in a subprocess in the near future <https://github.com/firezone/firezone/issues/2975>)
///
/// In total there are 4 subcommands (non-elevated, elevated GUI, crash handler, and deep link process)
/// In steady state, the only processes running will be the GUI and the crash handler.
pub(crate) fn run() -> Result<()> {
    std::panic::set_hook(Box::new(tracing_panic::panic_hook));
    let cli = Cli::parse();

    match cli.command {
        None => {
            if elevation::check()? {
                // We're already elevated, just run the GUI
                gui::run(GuiParams {
                    crash_on_purpose: cli.crash_on_purpose,
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
        Some(Cmd::CrashHandlerServer { socket_path }) => crash_handling::server(socket_path),
        Some(Cmd::Debug { command }) => debug_commands::run(command),
        // If we already tried to elevate ourselves, don't try again
        Some(Cmd::Elevated) => gui::run(GuiParams {
            crash_on_purpose: cli.crash_on_purpose,
            flag_elevated: true,
            inject_faults: cli.inject_faults,
        }),
        Some(Cmd::OpenDeepLink(deep_link)) => {
            let rt = tokio::runtime::Runtime::new()?;
            rt.block_on(deep_link::open(&deep_link.url))?;
            Ok(())
        }
    }
}

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Option<Cmd>,
    #[arg(long, hide = true)]
    crash_on_purpose: bool,
    #[arg(long, hide = true)]
    inject_faults: bool,
}

#[derive(clap::Subcommand)]
pub enum Cmd {
    CrashHandlerServer {
        socket_path: PathBuf,
    },
    Debug {
        #[command(subcommand)]
        command: debug_commands::Cmd,
    },
    Elevated,
    OpenDeepLink(DeepLink),
}

#[derive(Args)]
pub struct DeepLink {
    pub url: url::Url,
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
