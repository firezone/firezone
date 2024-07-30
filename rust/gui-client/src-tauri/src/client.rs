use anyhow::{bail, Result};
use clap::{Args, Parser};
use std::path::PathBuf;
use tracing::instrument;
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
const GIT_VERSION: &str = git_version::git_version!(
    args = ["--always", "--dirty=-modified", "--tags"],
    fallback = "unknown"
);

#[derive(Debug, thiserror::Error)]
pub(crate) enum Error {
    #[error("GUI module error: {0}")]
    Gui(#[from] gui::Error),
}

/// The program's entry point, equivalent to `main`
#[instrument(skip_all)]
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
                    gui::show_error_dialog(&error);
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
            let logging::Handles {
                logger: _logger,
                reloader,
            } = start_logging(&settings.log_filter)?;
            let result = gui::run(cli, settings, reloader);
            if let Err(error) = &result {
                // In smoke-test mode, don't show the dialog, since it might be running
                // unattended in CI and the dialog would hang forever

                // Because of <https://github.com/firezone/firezone/issues/3567>,
                // errors returned from `gui::run` may not be logged correctly
                tracing::error!(?error);
            }
            Ok(result?)
        }
    }
}

/// `gui::run` but wrapped in `anyhow::Result`
///
/// Automatically logs or shows error dialogs for important user-actionable errors
// Can't `instrument` this because logging isn't running when we enter it.
fn run_gui(cli: Cli) -> Result<()> {
    let mut settings = settings::load_advanced_settings().unwrap_or_default();
    fix_log_filter(&mut settings);
    let logging::Handles {
        logger: _logger,
        reloader,
    } = start_logging(&settings.log_filter)?;
    let result = gui::run(cli, settings, reloader);

    // Make sure errors get logged, at least to stderr
    if let Err(error) = &result {
        tracing::error!(?error, error_msg = %error);
        gui::show_error_dialog(error);
    }

    Ok(result?)
}

/// Parse the log filter from settings, showing an error and fixing it if needed
fn fix_log_filter(settings: &mut AdvancedSettings) {
    if EnvFilter::try_new(&settings.log_filter).is_ok() {
        return;
    }
    settings.log_filter = AdvancedSettings::default().log_filter;

    rfd::MessageDialog::new()
        .set_title("Log filter error")
        .set_description("The custom log filter is not parsable. Using the default log filter.")
        .set_level(rfd::MessageLevel::Error)
        .show();
}

/// Starts logging
///
/// Don't drop the log handle or logging will stop.
fn start_logging(directives: &str) -> Result<logging::Handles> {
    let logging_handles = logging::setup(directives)?;
    tracing::info!(
        arch = std::env::consts::ARCH,
        ?directives,
        ?GIT_VERSION,
        system_uptime_seconds = firezone_headless_client::uptime::get().map(|dur| dur.as_secs()),
        "`gui-client` started logging"
    );

    Ok(logging_handles)
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
    /// SmokeTest gets its own subcommand for historical reasons.
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
