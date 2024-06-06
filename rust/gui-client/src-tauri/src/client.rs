use anyhow::{bail, Context as _, Result};
use clap::{Args, Parser};
use connlib_client_shared::file_logger;
use firezone_headless_client::FIREZONE_GROUP;
use std::path::PathBuf;
use tracing_subscriber::EnvFilter;

mod about;
mod auth;
mod crash_handling;
mod debug_commands;
mod deep_link;
mod elevation;
mod gui;
mod ipc;
mod logging;
mod network_changes;
mod settings;
mod updates;
mod uptime;
mod welcome;

use settings::AdvancedSettings;

/// Output of `git describe` at compile time
/// e.g. `1.0.0-pre.4-20-ged5437c88-modified` where:
///
/// * `1.0.0-pre.4` is the most recent ancestor tag
/// * `20` is the number of commits since then
/// * `g` doesn't mean anything
/// * `ed5437c88` is the Git commit hash
/// * `-modified` is present if the working dir has any changes from that commit number
pub const GIT_VERSION: &str = git_version::git_version!(
    args = ["--always", "--dirty=-modified", "--tags"],
    fallback = "unknown"
);

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
        None => {
            match elevation::is_normal_user() {
                // Our elevation is correct (not elevated), just run the GUI
                Ok(true) => run_gui(cli),
                Ok(false) => bail!("The GUI should run as a normal user, not elevated"),
                Err(error) => {
                    show_error_dialog(&error)?;
                    Err(error.into())
                }
            }
        }
        Some(Cmd::CrashHandlerServer { socket_path }) => crash_handling::server(socket_path),
        Some(Cmd::Debug { command }) => debug_commands::run(command),
        // If we already tried to elevate ourselves, don't try again
        Some(Cmd::Elevated) => run_gui(cli),
        Some(Cmd::OpenDeepLink(deep_link)) => {
            let rt = tokio::runtime::Runtime::new()?;
            if let Err(error) = rt.block_on(deep_link::open(&deep_link.url)) {
                tracing::error!(?error, "Error in `OpenDeepLink`");
            }
            Ok(())
        }
        Some(Cmd::SmokeTest) => {
            if !elevation::is_normal_user()? {
                anyhow::bail!("`smoke-test` must run as a normal user");
            }

            let settings = settings::load_advanced_settings().unwrap_or_default();
            // Don't fix the log filter for smoke tests
            let _logger = start_logging(&settings.log_filter)?;
            let result = gui::run(cli, settings);
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

/// `gui::run` but wrapped in `anyhow::Result`
///
/// Automatically logs or shows error dialogs for important user-actionable errors
fn run_gui(cli: Cli) -> Result<()> {
    let mut settings = settings::load_advanced_settings().unwrap_or_default();
    fix_log_filter(&mut settings)?;
    let _logger = start_logging(&settings.log_filter)?;
    let result = gui::run(cli, settings);

    // Make sure errors get logged, at least to stderr
    if let Err(error) = &result {
        tracing::error!(?error, error_msg = error.to_string(), "`gui::run` error");
        show_error_dialog(error)?;
    }

    Ok(result?)
}

/// Parse the log filter from settings, showing an error and fixing it if needed
fn fix_log_filter(settings: &mut AdvancedSettings) -> Result<()> {
    if EnvFilter::try_new(&settings.log_filter).is_ok() {
        return Ok(());
    }
    settings.log_filter = AdvancedSettings::default().log_filter;

    native_dialog::MessageDialog::new()
        .set_title("Log filter error")
        .set_text("The custom log filter is not parsable. Using the default log filter.")
        .set_type(native_dialog::MessageType::Error)
        .show_alert()
        .context("Can't show log filter error dialog")?;

    Ok(())
}

/// Starts logging
///
/// Don't drop the log handle or logging will stop.
fn start_logging(directives: &str) -> Result<file_logger::Handle> {
    let logging_handles = logging::setup(directives)?;
    tracing::info!(?GIT_VERSION, "`gui-client` started logging");

    Ok(logging_handles.logger)
}

fn show_error_dialog(error: &gui::Error) -> Result<()> {
    // Decision to put the error strings here: <https://github.com/firezone/firezone/pull/3464#discussion_r1473608415>
    // This message gets shown to users in the GUI and could be localized, unlike
    // messages in the log which only need to be used for `git grep`.
    let user_friendly_error_msg = match error {
        // TODO: Update this URL
        gui::Error::WebViewNotInstalled => "Firezone cannot start because WebView2 is not installed. Follow the instructions at <https://www.firezone.dev/kb/user-guides/windows-client>.".to_string(),
        gui::Error::DeepLink(deep_link::Error::CantListen) => "Firezone is already running. If it's not responding, force-stop it.".to_string(),
        gui::Error::DeepLink(deep_link::Error::Other(error)) => error.to_string(),
        gui::Error::Logging(_) => "Logging error".to_string(),
        gui::Error::UserNotInFirezoneGroup => format!("You are not a member of the group `{FIREZONE_GROUP}`. Try `sudo usermod -aG {FIREZONE_GROUP} $USER` and then reboot"),
        gui::Error::Other(error) => error.to_string(),
    };
    tracing::error!("{}", user_friendly_error_msg);

    native_dialog::MessageDialog::new()
        .set_title("Firezone Error")
        .set_text(&user_friendly_error_msg)
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
    /// Disable deep link registration and handling, for headless CI environments
    #[arg(long, hide = true)]
    no_deep_links: bool,
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
    // TODO: Should be `Secret`?
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
