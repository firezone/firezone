//! The Firezone GUI client for Linux and Windows

// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{Context as _, Result, bail};
use clap::{Args, Parser};
use controller::Failure;
use firezone_telemetry::Telemetry;
use settings::AdvancedSettings;
use tracing_subscriber::EnvFilter;

mod about;
mod auth;
mod controller;
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

/// The Sentry "release" we are part of.
///
/// IPC service and GUI client are always bundled into a single release.
/// Hence, we have a single constant for IPC service and GUI client.
const RELEASE: &str = concat!("gui-client@", env!("CARGO_PKG_VERSION"));

fn main() -> anyhow::Result<()> {
    // Mitigates a bug in Ubuntu 22.04 - Under Wayland, some features of the window decorations like minimizing, closing the windows, etc., doesn't work unless you double-click the titlebar first.
    // SAFETY: No other thread is running yet
    unsafe {
        std::env::set_var("GDK_BACKEND", "x11");
    }

    let cli = Cli::parse();

    // TODO: Remove, this is only needed for Portal connections and the GUI process doesn't connect to the Portal. Unless it's also needed for update checks.
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Calling `install_default` only once per process should always succeed");

    match cli.command {
        None => {
            if cli.no_deep_links {
                return run_gui(cli);
            }
            match elevation::gui_check() {
                // Our elevation is correct (not elevated), just run the GUI
                Ok(true) => run_gui(cli),
                Ok(false) => bail!("The GUI should run as a normal user, not elevated"),
                #[cfg(target_os = "linux")] // Windows/MacOS elevation check never fails.
                Err(error) => {
                    show_error_dialog(&error.user_friendly_msg())?;
                    Err(error.into())
                }
            }
        }
        Some(Cmd::Debug { command }) => debug_commands::run(command),
        // If we already tried to elevate ourselves, don't try again
        Some(Cmd::Elevated) => run_gui(cli),
        Some(Cmd::OpenDeepLink(deep_link)) => {
            let rt = tokio::runtime::Runtime::new()?;
            if let Err(error) = rt.block_on(deep_link::open(&deep_link.url)) {
                tracing::error!("Error in `OpenDeepLink`: {error:#}");
            }
            Ok(())
        }
        Some(Cmd::SmokeTest) => {
            // Can't check elevation here because the Windows CI is always elevated
            let settings = settings::load_advanced_settings().unwrap_or_default();
            let mut telemetry = Telemetry::default();
            telemetry.start(
                settings.api_url.as_ref(),
                crate::RELEASE,
                firezone_telemetry::GUI_DSN,
            );
            // Don't fix the log filter for smoke tests
            let logging::Handles {
                logger: _logger,
                reloader,
            } = start_logging(&settings.log_filter)?;
            let result = gui::run(cli, settings, reloader, telemetry);
            if let Err(error) = &result {
                // In smoke-test mode, don't show the dialog, since it might be running
                // unattended in CI and the dialog would hang forever

                // Because of <https://github.com/firezone/firezone/issues/3567>,
                // errors returned from `gui::run` may not be logged correctly
                tracing::error!("{error:#}");
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
    let mut telemetry = Telemetry::default();
    // In the future telemetry will be opt-in per organization, that's why this isn't just at the top of `main`
    telemetry.start(
        settings.api_url.as_ref(),
        crate::RELEASE,
        firezone_telemetry::GUI_DSN,
    );
    // Get the device ID before starting Tokio, so that all the worker threads will inherit the correct scope.
    // Technically this means we can fail to get the device ID on a newly-installed system, since the IPC service may not have fully started up when the GUI process reaches this point, but in practice it's unlikely.
    if let Ok(id) = firezone_headless_client::device_id::get() {
        Telemetry::set_firezone_id(id.id);
    }
    fix_log_filter(&mut settings)?;
    let logging::Handles {
        logger: _logger,
        reloader,
    } = start_logging(&settings.log_filter)?;

    match gui::run(cli, settings, reloader, telemetry) {
        Ok(()) => Ok(()),
        Err(anyhow) => {
            if anyhow
                .chain()
                .find_map(|e| e.downcast_ref::<tauri_runtime::Error>())
                .is_some_and(|e| matches!(e, tauri_runtime::Error::CreateWebview(_)))
            {
                show_error_dialog(
                    "Firezone cannot start because WebView2 is not installed. Follow the instructions at <https://www.firezone.dev/kb/client-apps/windows-gui-client>.",
                )?;
                return Err(anyhow);
            }

            if anyhow.root_cause().is::<deep_link::CantListen>() {
                show_error_dialog(
                    "Firezone is already running. If it's not responding, force-stop it.",
                )?;
                return Err(anyhow);
            }

            if anyhow
                .root_cause()
                .is::<firezone_headless_client::ipc::NotFound>()
            {
                show_error_dialog("Couldn't find Firezone IPC service. Is the service running?")?;
                return Err(anyhow);
            }

            show_error_dialog(
                "An unexpected error occurred. Please try restarting Firezone. If the issue persists, contact your administrator.",
            )?;
            tracing::error!("GUI failed: {anyhow:#}");

            Err(anyhow)
        }
    }
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

/// Blocks the thread and shows an error dialog
///
/// Doesn't play well with async, only use this if we're bailing out of the
/// entire process.
fn show_error_dialog(msg: &str) -> Result<()> {
    // I tried the Tauri dialogs and for some reason they don't show our
    // app icon.
    native_dialog::MessageDialog::new()
        .set_title("Firezone Error")
        .set_text(msg)
        .set_type(native_dialog::MessageType::Error)
        .show_alert()?;
    Ok(())
}

/// Starts logging
///
/// Don't drop the log handle or logging will stop.
fn start_logging(directives: &str) -> Result<logging::Handles> {
    let logging_handles = logging::setup(directives)?;
    let system_uptime_seconds = firezone_bin_shared::uptime::get().map(|dur| dur.as_secs());
    tracing::info!(
        arch = std::env::consts::ARCH,
        os = std::env::consts::OS,
        version = env!("CARGO_PKG_VERSION"),
        ?directives,
        ?system_uptime_seconds,
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
    /// If true, check for updates every 30 seconds and pretend our current version is 1.0.0, so we'll always show the notification dot.
    #[arg(long, hide = true)]
    debug_update_check: bool,
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

    /// Quit gracefully after a given number of seconds
    #[arg(long, hide = true)]
    quit_after: Option<u64>,

    /// If true, slow down I/O operations to test how the GUI handles slow I/O
    #[arg(long, hide = true)]
    inject_faults: bool,
    /// If true, show a fake update notification that opens the Firezone release page when clicked
    #[arg(long, hide = true)]
    test_update_notification: bool,
    /// For headless CI, disable deep links and allow the GUI to run as admin
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

#[derive(clap::Subcommand)]
enum Cmd {
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
