//! The Firezone GUI client for Linux and Windows

// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::process::ExitCode;

use anyhow::{Context as _, ErrorExt, Result, bail};
use clap::{Args, Parser};
use controller::Failure;
use firezone_gui_client::{controller, deep_link, elevation, gui, logging, settings};
use settings::AdvancedSettingsLegacy;
use telemetry::Telemetry;
use tokio::runtime::Runtime;
use tracing::subscriber::DefaultGuard;
use tracing_subscriber::EnvFilter;

fn main() -> ExitCode {
    let mut bootstrap_log_guard =
        Some(logging::setup_bootstrap().expect("Failed to setup bootstrap logger"));

    let cli = Cli::parse();

    let mut telemetry = if cli.is_telemetry_allowed() {
        Telemetry::new()
    } else {
        Telemetry::disabled()
    };

    let rt = tokio::runtime::Runtime::new().expect("failed to build runtime");

    match try_main(cli, &rt, &mut bootstrap_log_guard, &mut telemetry) {
        Ok(()) => {
            rt.block_on(telemetry.stop());

            ExitCode::SUCCESS
        }
        Err(e) => {
            tracing::error!("GUI failed: {e:#}");

            rt.block_on(telemetry.stop_on_crash());

            ExitCode::FAILURE
        }
    }
}

fn try_main(
    cli: Cli,
    rt: &Runtime,
    bootstrap_log_guard: &mut Option<DefaultGuard>,
    telemetry: &mut Telemetry,
) -> Result<()> {
    let config = gui::RunConfig {
        inject_faults: cli.inject_faults,
        debug_update_check: cli.debug_update_check,
        smoke_test: cli
            .command
            .as_ref()
            .is_some_and(|c| matches!(c, Cmd::SmokeTest)),
        no_deep_links: cli.no_deep_links,
        quit_after: cli.quit_after,
        fail_with: cli.fail_on_purpose(),
    };

    let mut advanced_settings =
        settings::load_advanced_settings::<AdvancedSettingsLegacy>().unwrap_or_default();

    let mdm_settings = settings::load_mdm_settings()
        .inspect_err(|e| tracing::debug!("Failed to load MDM settings {e:#}"))
        .unwrap_or_default();

    let api_url = mdm_settings
        .api_url
        .as_ref()
        .unwrap_or(&advanced_settings.api_url)
        .to_string();

    // Get the device ID before starting Tokio, so that all the worker threads will inherit the correct scope.
    // Technically this means we can fail to get the device ID on a newly-installed system, since the Tunnel service may not have fully started up when the GUI process reaches this point, but in practice it's unlikely.
    let id = bin_shared::device_id::get_client().context("Failed to get device ID")?;

    if cli.is_telemetry_allowed() {
        rt.block_on(telemetry.start(
            &api_url,
            firezone_gui_client::RELEASE,
            telemetry::GUI_DSN,
            id.id,
        ));
    }

    // Don't fix the log filter for smoke tests because we can't show a dialog there.
    if !config.smoke_test {
        fix_log_filter(&mut advanced_settings)?;
    }

    let log_filter = std::env::var("RUST_LOG")
        .ok()
        .or(mdm_settings.log_filter.clone())
        .unwrap_or_else(|| advanced_settings.log_filter.clone());

    drop(bootstrap_log_guard.take());

    let logging::Handles {
        logger: _logger,
        reloader,
    } = firezone_gui_client::logging::setup_gui(&log_filter)?;

    match cli.command {
        None if cli.check_elevation() => match elevation::gui_check() {
            Ok(true) => {}
            Ok(false) => bail!("The GUI should run as a normal user, not elevated"),
            #[cfg(target_os = "linux")] // Windows/MacOS elevation check never fails.
            Err(error) => {
                show_error_dialog(&error.user_friendly_msg())?;

                return Err(error.into());
            }
        },
        None | Some(Cmd::Elevated) => {
            // Fall-through to running the GUI if elevation check should be bypassed.
        }

        // All commands below _don't_ end up running the GUI because they return early.
        Some(Cmd::Debug {
            command: DebugCommand::Replicate6791,
        }) => {
            firezone_gui_client::auth::replicate_6791()?;

            return Ok(());
        }
        Some(Cmd::Debug {
            command: DebugCommand::SetAutostart(SetAutostartArgs { enabled }),
        }) => {
            rt.block_on(firezone_gui_client::gui::set_autostart(enabled))?;

            return Ok(());
        }
        Some(Cmd::OpenDeepLink(deep_link)) => {
            tracing::info!("Opening deep-link");

            rt.block_on(deep_link::open(deep_link.url))
                .context("Failed to open deep-link")?;

            return Ok(());
        }
        Some(Cmd::SmokeTest) => {
            // Can't check elevation here because the Windows CI is always elevated
            gui::run(rt, config, mdm_settings, advanced_settings, reloader)?;

            return Ok(());
        }
    };

    // Happy-path: Run the GUI.

    match gui::run(rt, config, mdm_settings, advanced_settings, reloader) {
        Ok(()) => {}
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

            if anyhow.any_is::<gui::AlreadyRunning>() {
                return Ok(());
            }

            if anyhow.any_is::<gui::NewInstanceHandshakeFailed>() {
                show_error_dialog(
                    "Firezone is already running but not responding. Please force-stop it first.",
                )?;
                return Err(anyhow);
            }

            if anyhow.any_is::<firezone_gui_client::ipc::NotFound>() {
                show_error_dialog(
                    "Couldn't find Firezone Tunnel service. Is the service running?",
                )?;
                return Err(anyhow);
            }

            if anyhow.any_is::<controller::FailedToReceiveHello>() {
                show_error_dialog(
                    "The Firezone Tunnel service is not responding. If the issue persists, contact your administrator.",
                )?;
                return Err(anyhow);
            }

            show_error_dialog(
                "An unexpected error occurred. Please try restarting Firezone. If the issue persists, contact your administrator.",
            )?;

            return Err(anyhow);
        }
    };

    Ok(())
}

/// Parse the log filter from settings, showing an error and fixing it if needed
fn fix_log_filter(settings: &mut AdvancedSettingsLegacy) -> Result<()> {
    if EnvFilter::try_new(&settings.log_filter).is_ok() {
        return Ok(());
    }
    settings.log_filter = AdvancedSettingsLegacy::default().log_filter;

    native_dialog::DialogBuilder::message()
        .set_title("Log filter error")
        .set_text("The custom log filter is not parsable. Using the default log filter.")
        .set_type(native_dialog::MessageLevel::Error)
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
    native_dialog::DialogBuilder::message()
        .set_title("Firezone Error")
        .set_text(msg)
        .set_type(native_dialog::MessageLevel::Error)
        .show_alert()?;
    Ok(())
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
    /// For headless CI, disable deep links.
    #[arg(long, hide = true)]
    no_deep_links: bool,
    /// For headless CI, disable the elevation check.
    #[arg(long, hide = true)]
    no_elevation_check: bool,

    /// Disable sentry.io crash-reporting agent.
    #[arg(
        long,
        env = "FIREZONE_NO_TELEMETRY",
        default_value_t = false,
        hide = true
    )]
    no_telemetry: bool,
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

    fn check_elevation(&self) -> bool {
        !self.no_elevation_check
    }

    fn is_telemetry_allowed(&self) -> bool {
        !self.no_telemetry
    }
}

#[derive(clap::Subcommand)]
enum Cmd {
    Debug {
        #[command(subcommand)]
        command: DebugCommand,
    },
    Elevated,
    OpenDeepLink(DeepLink),
    /// SmokeTest gets its own subcommand for historical reasons.
    SmokeTest,
}

#[derive(clap::Subcommand)]
enum DebugCommand {
    Replicate6791,
    SetAutostart(SetAutostartArgs),
}

#[derive(clap::Parser)]
struct SetAutostartArgs {
    #[clap(action=clap::ArgAction::Set)]
    enabled: bool,
}

#[derive(clap::Parser)]
struct CheckTokenArgs {
    token: String,
}

#[derive(clap::Parser)]
struct StoreTokenArgs {
    token: String,
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
        assert!(!path.contains('\"'), "`{path}`");
        Ok(())
    }
}
