#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::anyhow;
use bin_shared::{DnsControlMethod, TOKEN_ENV_KEY};
use clap::Parser as _;
use firezone_gui_client::service;
use std::path::PathBuf;

fn main() -> anyhow::Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|_| anyhow!("Failed to install default crypto provider"))?;

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
        Cmd::Install => service::install(),
        Cmd::Run => service::run(cli.log_dir, cli.dns_control),
        Cmd::RunDebug => service::run_debug(cli.dns_control),
        Cmd::RunSmokeTest => service::run_smoke_test(),
    }
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

#[derive(clap::Subcommand, Default)]
enum Cmd {
    /// Needed to test the Tunnel service on aarch64 Windows,
    /// where the Tauri MSI bundler doesn't work yet
    Install,
    #[default]
    Run,
    RunDebug,
    RunSmokeTest,
}

#[cfg(test)]
mod tests {
    use super::{Cli, Cmd};
    use clap::Parser;
    use std::path::PathBuf;

    const EXE_NAME: &str = "firezone-client-tunnel";

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
