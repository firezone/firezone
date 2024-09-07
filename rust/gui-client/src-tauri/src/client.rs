use anyhow::{bail, Context as _, Result};
use clap::{Args, Parser};
use firezone_gui_client_common::{
    self as common,
    cli::{Cli, Cmd, Failure},
    crash_handling, debug_commands, deep_link,
    settings::AdvancedSettings,
};
use std::path::PathBuf;
use tracing::instrument;
use tracing_subscriber::EnvFilter;

mod about;
mod elevation;
mod gui;
mod logging;
mod settings;
mod welcome;

#[derive(Debug, thiserror::Error)]
pub(crate) enum Error {
    #[error("GUI module error: {0}")]
    Gui(#[from] common::errors::Error),
}

/// The program's entry point, equivalent to `main`
#[instrument(skip_all)]
pub(crate) fn run() -> Result<()> {
    std::panic::set_hook(Box::new(tracing_panic::panic_hook));
    let cli = Cli::parse();

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
                Err(error) => {
                    common::errors::show_error_dialog(&error)?;
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
            // Can't check elevation here because the Windows CI is always elevated
            let settings = common::settings::load_advanced_settings().unwrap_or_default();
            // Don't fix the log filter for smoke tests
            let common::logging::Handles {
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
    let mut settings = common::settings::load_advanced_settings().unwrap_or_default();
    fix_log_filter(&mut settings)?;
    let common::logging::Handles {
        logger: _logger,
        reloader,
    } = start_logging(&settings.log_filter)?;
    let result = gui::run(cli, settings, reloader);

    // Make sure errors get logged, at least to stderr
    if let Err(error) = &result {
        tracing::error!(?error, error_msg = %error);
        common::errors::show_error_dialog(error)?;
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
fn start_logging(directives: &str) -> Result<common::logging::Handles> {
    let logging_handles = common::logging::setup(directives)?;
    tracing::info!(
        arch = std::env::consts::ARCH,
        os = std::env::consts::OS,
        ?directives,
        git_version = firezone_bin_shared::git_version!("gui-client-*"),
        system_uptime_seconds = firezone_headless_client::uptime::get().map(|dur| dur.as_secs()),
        "`gui-client` started logging"
    );

    Ok(logging_handles)
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
