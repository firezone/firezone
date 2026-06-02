//! The Firezone GUI client for Linux and Windows

// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::process::ExitCode;

use anyhow::{Context as _, ErrorExt, Result, bail};
use clap::{Args, Parser};
use controller::Failure;
use firezone_gui_client::{controller, deep_link, dialog, elevation, gui, logging, settings};
use settings::AdvancedSettings;
use telemetry::Telemetry;
use tokio::runtime::Runtime;
use tracing::subscriber::DefaultGuard;
use tracing_subscriber::EnvFilter;

#[expect(
    dead_code,
    reason = "Variants are held only for their `Drop` side effects."
)]
enum LogGuard {
    /// Pre-settings bootstrap logger: a thread-local default that must
    /// be dropped before the global GUI logger is installed.
    Bootstrap(DefaultGuard),
    /// GUI file logger and log-cleanup thread.
    Gui(logging::file::Handle, logging::CleanupHandle),
}

fn main() -> ExitCode {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Failed to install default crypto provider");

    let mut log_guard = Some(LogGuard::Bootstrap(
        logging::setup_bootstrap().expect("Failed to setup bootstrap logger"),
    ));

    let cli = Cli::parse();
    let rt = tokio::runtime::Runtime::new().expect("failed to build runtime");

    let mut telemetry = if cli.is_telemetry_allowed() {
        Telemetry::new()
    } else {
        Telemetry::disabled()
    };

    // Start telemetry in `entrypoint` mode so that crashes during settings
    // load, Tauri setup, IPC connect, or the Hello-wait window are captured.
    // `try_main` will switch the env to the real api_url once it has loaded
    // settings; on graceful exit we flush below.
    telemetry.start(
        "entrypoint",
        firezone_gui_client::RELEASE,
        telemetry::GUI_DSN,
    );

    let result = try_main(cli, &rt, &mut log_guard, &mut telemetry);

    rt.block_on(telemetry.stop());

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            tracing::error!("GUI failed: {e:#}");

            ExitCode::FAILURE
        }
    }
}

fn try_main(
    cli: Cli,
    rt: &Runtime,
    log_guard: &mut Option<LogGuard>,
    telemetry: &mut Telemetry,
) -> Result<()> {
    #[cfg(debug_assertions)]
    if cli.skip_tunnel_pipe_owner_check {
        firezone_gui_client::ipc::skip_tunnel_pipe_owner_check();
    }

    #[cfg(debug_assertions)]
    if cli.skip_portal_auth {
        firezone_gui_client::auth::skip_portal_auth();
    }

    #[cfg(debug_assertions)]
    if cli.mock_tunnel {
        firezone_gui_client::mock_tunnel::enable();
    }

    if cli.test_error_dialog {
        dialog::error("Dialogs are working!")?;
    }

    let config = gui::RunConfig {
        inject_faults: cli.inject_faults,
        debug_update_check: cli.debug_update_check,
        smoke_test: cli
            .command
            .as_ref()
            .is_some_and(|c| matches!(c, Cmd::SmokeTest)),
        no_deep_links: cli.no_deep_links,
        telemetry_allowed: cli.is_telemetry_allowed(),
        quit_after: cli.quit_after,
        fail_with: cli.fail_on_purpose(),
    };

    let mut advanced_settings = settings::load_advanced_settings().unwrap_or_default();

    let mdm_settings = settings::load_mdm_settings()
        .inspect_err(|e| tracing::debug!("Failed to load MDM settings {e:#}"))
        .unwrap_or_default();

    // Now that we know the real api_url, switch the Sentry session out of
    // entrypoint mode. `Telemetry::start` notices the env change and stops
    // the previous session before initialising a new one.
    let api_url = mdm_settings
        .api_url
        .as_ref()
        .unwrap_or(&advanced_settings.api_url)
        .to_string();
    telemetry.start(&api_url, firezone_gui_client::RELEASE, telemetry::GUI_DSN);

    // Don't fix the log filter for smoke tests because we can't show a dialog there.
    if !config.smoke_test {
        fix_log_filter(&mut advanced_settings)?;
    }

    let log_filter = std::env::var("RUST_LOG")
        .ok()
        .or(mdm_settings.log_filter.clone())
        .unwrap_or_else(|| advanced_settings.log_filter.clone());

    *log_guard = None;

    let logging::Handles {
        logger,
        reloader,
        cleanup,
    } = firezone_gui_client::logging::setup_gui(&log_filter)?;

    *log_guard = Some(LogGuard::Gui(logger, cleanup));

    match cli.command {
        None if cli.check_elevation() => match elevation::gui_check() {
            Ok(true) => {}
            Ok(false) => bail!("The GUI should run as a normal user, not elevated"),
            #[cfg(target_os = "linux")] // Windows/MacOS elevation check never fails.
            Err(error) => {
                dialog::error(&error.user_friendly_msg())?;

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
        Some(Cmd::Debug {
            command: DebugCommand::SingleInstance,
        }) => {
            rt.block_on(debug_single_instance())?;

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
            if cli.no_error_dialog {
                return Err(anyhow);
            }

            if anyhow
                .chain()
                .find_map(|e| e.downcast_ref::<tauri_runtime::Error>())
                .is_some_and(|e| matches!(e, tauri_runtime::Error::CreateWebview(_)))
            {
                dialog::error(
                    "Firezone cannot start because WebView2 is not installed. Follow the instructions at <https://www.firezone.dev/kb/client-apps/windows-gui-client>.",
                )?;
                return Err(anyhow);
            }

            if anyhow.any_is::<gui::AlreadyRunning>() {
                return Ok(());
            }

            if anyhow.any_is::<firezone_gui_client::package_identity::RestartRequired>() {
                dialog::info("Firezone finished first-time setup. Please start Firezone again.")?;
                return Ok(());
            }

            if anyhow.any_is::<firezone_gui_client::ipc::WrongUser>() {
                dialog::error(
                    "Firezone is already running in another logon session. \
                     Sign out of that session first, then try again.",
                )?;
                return Ok(());
            }

            if anyhow.any_is::<gui::NewInstanceHandshakeFailed>() {
                dialog::error(
                    "Firezone is already running but not responding. Please force-stop it first.",
                )?;
                return Err(anyhow);
            }

            if anyhow.any_is::<firezone_gui_client::ipc::NotFound>() {
                dialog::error("Couldn't find Firezone Tunnel service. Is the service running?")?;
                return Err(anyhow);
            }

            if anyhow.any_is::<controller::FailedToReceiveHello>() {
                dialog::error(
                    "The Firezone Tunnel service is not responding. If the issue persists, contact your administrator.",
                )?;
                return Err(anyhow);
            }

            dialog::error(
                "An unexpected error occurred. Please try restarting Firezone. If the issue persists, contact your administrator.",
            )?;

            return Err(anyhow);
        }
    };

    Ok(())
}

/// Parse the log filter from settings, showing an error and fixing it if needed
fn fix_log_filter(settings: &mut AdvancedSettings) -> Result<()> {
    if EnvFilter::try_new(&settings.log_filter).is_ok() {
        return Ok(());
    }
    settings.log_filter = AdvancedSettings::default().log_filter;

    firezone_gui_client::dialog::error(
        "The custom log filter is not parsable. Using the default log filter.",
    )?;

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
    /// If true, show a fake error dialog on startup
    #[arg(long, hide = true)]
    test_error_dialog: bool,
    /// For headless CI, disable deep links.
    #[arg(long, hide = true)]
    no_deep_links: bool,
    /// For headless CI, log errors instead of showing a blocking
    /// dialog (which would hang with no one to dismiss it).
    #[arg(long, hide = true)]
    no_error_dialog: bool,
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

    /// Windows-only smoke-test escape hatch: skip the LocalSystem owner check
    /// on the Tunnel named pipe. Only exists in debug builds, so release
    /// binaries can't disable the check.
    #[cfg(debug_assertions)]
    #[arg(long, hide = true)]
    skip_tunnel_pipe_owner_check: bool,

    /// Decouple sign-in from the portal: mint a fake session/token on the fly
    /// (never persisted) instead of opening the browser. Pairs with
    /// `--mock-tunnel`. Debug builds only.
    #[cfg(debug_assertions)]
    #[arg(long, hide = true)]
    skip_portal_auth: bool,

    /// Mock the Tunnel service in-process: serve a canned resource list over an
    /// in-memory IPC channel instead of connecting to the real (root-only)
    /// Tunnel service. Pairs with `--skip-portal-auth`. Debug builds only.
    #[cfg(debug_assertions)]
    #[arg(long, hide = true)]
    mock_tunnel: bool,
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
    /// Drive only the launch-lock + GUI IPC handshake — no controller, no
    /// auth, no tunnel-service IPC, no Tauri UI. Two invocations exercise
    /// the single-instance hand-off end to end:
    ///
    /// - First invocation: acquires the lock, binds the GUI pipe, prints
    ///   `first-instance: …`, accepts one client, acks, and exits.
    /// - Second invocation: sees the lock held, connects to the pipe,
    ///   sends `NewInstance`, awaits the `Ack`, prints
    ///   `second-instance: …`, and exits.
    SingleInstance,
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

/// Drives the launch-lock + GUI-pipe handshake to exit cleanly as
/// either the first or second instance. Run twice (concurrently from
/// a shell smoke test, or by hand from two terminals) to exercise
/// the hand-off path; the two stdout lines below let the harness
/// assert on the outcome.
#[allow(
    clippy::print_stdout,
    reason = "the whole point of this subcommand is to print a smoke-test signal to stdout"
)]
async fn debug_single_instance() -> anyhow::Result<()> {
    use firezone_gui_client::gui::{self, SingleInstance};

    match gui::establish_single_instance().await? {
        SingleInstance::First {
            mut server,
            lock: _lock,
        } => {
            println!("first-instance: lock acquired; waiting for one client");
            let msg = gui::accept_one_for_debug(&mut server).await?;
            println!("first-instance: received {msg:?}; acked, exiting");
        }
        SingleInstance::SecondHandedOff => {
            println!("second-instance: handshake completed, exiting");
        }
    }
    Ok(())
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
