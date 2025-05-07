#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{Result, bail};
use clap::Parser as _;
use firezone_bin_shared::{DnsControlMethod, TOKEN_ENV_KEY, signals};
use firezone_gui_client::service;
use firezone_telemetry::Telemetry;
use std::path::PathBuf;

fn main() -> anyhow::Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Calling `install_default` only once per process should always succeed");

    // Docs indicate that `remove_var` should actually be marked unsafe
    // SAFETY: We haven't spawned any other threads, this code should be the first
    // thing to run after entering `main` and parsing CLI args.
    // So nobody else is reading the environment.
    unsafe {
        // This removes the token from the environment per <https://security.stackexchange.com/a/271285>. We run as root so it may not do anything besides defense-in-depth.
        std::env::remove_var(TOKEN_ENV_KEY);
    }
    assert!(std::env::var(TOKEN_ENV_KEY).is_err());

    let cli = Cli::try_parse()?;

    match cli.command {
        Cmd::Install => service::install_ipc_service(),
        Cmd::Run => service::run_ipc_service(cli.log_dir, cli.dns_control),
        Cmd::RunDebug => run_debug_ipc_service(cli),
        Cmd::RunSmokeTest => service::run_smoke_test(),
    }
}

fn run_debug_ipc_service(cli: Cli) -> Result<()> {
    let log_filter_reloader = firezone_gui_client::logging::setup_stdout()?;
    tracing::info!(
        arch = std::env::consts::ARCH,
        // version = env!("CARGO_PKG_VERSION"), TODO: Fix once `ipc_service` is moved to `gui-client`.
        system_uptime_seconds = firezone_bin_shared::uptime::get().map(|dur| dur.as_secs()),
    );
    if !service::elevation_check()? {
        bail!("IPC service failed its elevation check, try running as admin / root");
    }
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let _guard = rt.enter();
    let mut signals = signals::Terminate::new()?;
    let mut telemetry = Telemetry::default();

    rt.block_on(service::ipc_listen(
        cli.dns_control,
        &log_filter_reloader,
        &mut signals,
        &mut telemetry,
    ))
    .inspect(|_| rt.block_on(telemetry.stop()))
    .inspect_err(|e| {
        tracing::error!("IPC service failed: {e:#}");

        rt.block_on(telemetry.stop_on_crash())
    })
}

#[derive(clap::Parser)]
#[command(author, version, about, long_about = None)]
pub struct Cli {
    #[command(subcommand)]
    command: Cmd,

    #[cfg(target_os = "linux")]
    #[arg(long, env = "FIREZONE_DNS_CONTROL", default_value = "systemd-resolved")]
    dns_control: DnsControlMethod,

    #[cfg(target_os = "windows")]
    #[arg(long, env = "FIREZONE_DNS_CONTROL", default_value = "nrpt")]
    dns_control: DnsControlMethod,

    #[cfg(target_os = "macos")]
    #[arg(long, env = "FIREZONE_DNS_CONTROL", default_value = "none")]
    dns_control: DnsControlMethod,

    /// File logging directory. Should be a path that's writeable by the current user.
    #[arg(short, long, env = "LOG_DIR")]
    log_dir: Option<PathBuf>,

    /// Maximum length of time to retry connecting to the portal if we're having internet issues or
    /// it's down. Accepts human times. e.g. "5m" or "1h" or "30d".
    #[arg(short, long, env = "MAX_PARTITION_TIME")]
    max_partition_time: Option<humantime::Duration>,
}

#[derive(clap::Subcommand)]
enum Cmd {
    /// Needed to test the IPC service on aarch64 Windows,
    /// where the Tauri MSI bundler doesn't work yet
    Install,
    Run,
    RunDebug,
    RunSmokeTest,
}

impl Default for Cmd {
    fn default() -> Self {
        Self::Run
    }
}

#[cfg(test)]
mod tests {
    use super::{Cli, Cmd};
    use clap::Parser;
    use std::path::PathBuf;

    const EXE_NAME: &str = "firezone-client-ipc";

    // Can't remember how Clap works sometimes
    // Also these are examples
    #[test]
    fn cli() {
        let actual =
            Cli::try_parse_from([EXE_NAME, "--log-dir", "bogus_log_dir", "run-debug"]).unwrap();
        assert!(matches!(actual.command, Cmd::RunDebug));
        assert_eq!(actual.log_dir, Some(PathBuf::from("bogus_log_dir")));

        let actual = Cli::try_parse_from([EXE_NAME, "run"]).unwrap();
        assert!(matches!(actual.command, Cmd::Run));
    }
}
