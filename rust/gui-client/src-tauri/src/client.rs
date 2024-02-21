use anyhow::Result;
use clap::{Args, Parser};
use std::path::PathBuf;

mod about;
mod auth;
mod crash_handling;
mod debug_commands;
mod device_id;
mod gui;
mod known_dirs;
mod logging;
mod resolvers;
mod settings;
mod updates;

#[cfg(target_os = "windows")]
mod deep_link;
#[cfg(target_os = "windows")]
mod elevation;
#[cfg(target_os = "windows")]
mod network_changes;
#[cfg(target_os = "windows")]
mod wintun_install;

#[cfg(not(target_os = "windows"))]
// TODO
mod deep_link {
    use crate::client::auth;
    use connlib_shared::control::SecureUrl;
    use secrecy::Secret;

    #[derive(thiserror::Error, Debug)]
    pub enum Error {
        #[error("Can't listen for deep links, Firezone is probably already running")]
        CantListen,
    }
    pub struct Server {}
    impl Server {
        pub fn new() -> Result<Self, Error> {
            if false {
                return Err(Error::CantListen);
            }
            Ok(Self {})
        }
        pub async fn accept(&self) -> Result<Secret<SecureUrl>, Error> {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(86400)).await;
            }
        }
    }
    pub async fn open(_url: &url::Url) -> Result<(), Error> {
        Ok(())
    }
    pub fn parse_auth_callback(_url: &Secret<SecureUrl>) -> Option<auth::Response> {
        None
    }
    pub fn register() -> Result<(), Error> {
        Ok(())
    }
}
#[cfg(not(target_os = "windows"))]
// TODO
mod elevation {}
#[cfg(not(target_os = "windows"))]
// TODO
mod network_changes {
    use anyhow::Result;
    use std::sync::Arc;
    use tokio::sync::Notify;

    #[derive(thiserror::Error, Debug)]
    pub enum Error {}
    pub struct Worker {
        notify: Arc<Notify>,
    }
    impl Worker {
        pub fn new() -> std::io::Result<Self> {
            let notify = Arc::new(Notify::new());
            Ok(Self { notify })
        }
        pub fn close(&mut self) -> Result<(), Error> {
            Ok(())
        }
        pub async fn notified(&self) {
            self.notify.notified().await;
        }
    }
    pub fn check_internet() -> Result<bool> {
        Ok(true)
    }
    pub fn run_debug() -> Result<()> {
        Ok(())
    }
}
#[cfg(not(target_os = "windows"))]
mod wintun_install {}

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

#[derive(Debug, thiserror::Error)]
pub(crate) enum Error {
    #[error("GUI module error: {0}")]
    Gui(#[from] gui::Error),
}

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
        None => run_default(cli),
        Some(Cmd::CrashHandlerServer { socket_path }) => crash_handling::server(socket_path),
        Some(Cmd::Debug { command }) => debug_commands::run(command),
        // If we already tried to elevate ourselves, don't try again
        Some(Cmd::Elevated) => run_gui(cli),
        Some(Cmd::OpenDeepLink(deep_link)) => {
            let rt = tokio::runtime::Runtime::new()?;
            rt.block_on(deep_link::open(&deep_link.url))?;
            Ok(())
        }
        Some(Cmd::SmokeTest) => {
            let result = gui::run(&cli);
            if let Err(error) = &result {
                // In smoke-test mode, don't show the dialog, since it might be running
                // unattended in CI and the dialog would hang forever

                // Because of <https://github.com/firezone/firezone/issues/3567>,
                // errors returned from `gui::run` may not be logged correctly
                tracing::error!(?error, "gui::run error");
            }
            Ok(result?)
        }
    }
}

#[cfg(target_os = "windows")]
fn run_default(cli: Cli) -> Result<()> {
    use std::os::windows::process::CommandExt;

    // Hides Powershell's console on Windows
    // <https://stackoverflow.com/questions/59692146/is-it-possible-to-use-the-standard-library-to-spawn-a-process-without-showing-th#60958956>
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    if elevation::check()? {
        // We're already elevated, just run the GUI
        run_gui(cli)
    } else {
        // We're not elevated, ask Powershell to re-launch us, then exit
        let current_exe = tauri_utils::platform::current_exe()?;
        if current_exe.display().to_string().contains('\"') {
            anyhow::bail!("The exe path must not contain double quotes, it makes it hard to elevate with Powershell");
        }
        std::process::Command::new("powershell")
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

#[cfg(not(target_os = "windows"))]
fn run_default(cli: Cli) -> Result<()> {
    run_gui(cli)
}

/// `gui::run` but wrapped in `anyhow::Result`
///
/// Automatically logs or shows error dialogs for important user-actionable errors
fn run_gui(cli: Cli) -> Result<()> {
    let result = gui::run(&cli);

    // Make sure errors get logged, at least to stderr
    if let Err(error) = &result {
        tracing::error!(?error, "gui::run error");
        show_error_dialog(error)?;
    }

    Ok(result?)
}

fn show_error_dialog(error: &gui::Error) -> Result<()> {
    let error_msg = match error {
        gui::Error::WebViewNotInstalled => "Firezone cannot start because WebView2 is not installed. Follow the instructions at <https://www.firezone.dev/kb/user-guides/windows-client>.".to_string(),
        gui::Error::DeepLink(deep_link::Error::CantListen) => "Firezone is already running. If it's not responding, force-stop it.".to_string(),
        error => error.to_string(),
    };

    native_dialog::MessageDialog::new()
        .set_title("Firezone Error")
        .set_text(&error_msg)
        .set_type(native_dialog::MessageType::Error)
        .show_alert()?;
    Ok(())
}

/// The debug / test flags like `crash_on_purpose` and `test_update_notification`
/// don't propagate when we use `RunAs` to elevate ourselves. So those must be run
/// from an admin terminal, or with "Run as administrator" in the right-click menu.
#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    /// If true, always show the update notification at startup, even if our version is newer than Github's
    #[arg(long, hide = true)]
    always_show_update_notification: bool,
    #[command(subcommand)]
    command: Option<Cmd>,

    /// Crash the `Controller` task to test error handling
    /// Formerly `--crash-on-purpose`
    #[arg(long, hide = true)]
    crash: bool,
    /// Error out of the `Controller` task to test error handling
    #[arg(long, hide = true)]
    error: bool,
    /// Panic the `Controller` task to test error handling
    #[arg(long, hide = true)]
    panic: bool,

    /// If true, slow down I/O operations to test how the GUI handles slow I/O
    #[arg(long, hide = true)]
    inject_faults: bool,
    /// If true, show a fake update notification that opens the Firezone release page when clicked
    #[arg(long, hide = true)]
    test_update_notification: bool,
}

impl Cli {
    fn fail_on_purpose(&self) -> Option<Failure> {
        if self.crash {
            Some(Failure::Crash)
        } else if self.error {
            Some(Failure::Error)
        } else if self.panic {
            Some(Failure::Panic)
        } else {
            None
        }
    }
}

// The failure flags are all mutually exclusive
// TODO: I can't figure out from the `clap` docs how to do this:
// `app --fail-on-purpose crash-in-wintun-worker`
// So the failure should be an `Option<Enum>` but _not_ a subcommand.
// You can only have one subcommand per container, I've tried
#[derive(Debug)]
enum Failure {
    Crash,
    Error,
    Panic,
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
    /// SmokeTest gets its own subcommand because elevating would start a new process and trash the exit code
    ///
    /// We could solve that by keeping the un-elevated process around, blocking on the elevated
    /// child process, but then we'd always have an extra process hanging around.
    ///
    /// It's also invalid for release builds, because we build the exe as a GUI app,
    /// so Windows won't give us a valid exit code, it'll just detach from the terminal instantly.
    SmokeTest,
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
