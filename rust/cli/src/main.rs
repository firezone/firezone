#![expect(clippy::print_stdout, reason = "We are a CLI.")]

use std::{process::Command, sync::LazyLock};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use secrecy::{ExposeSecret as _, SecretString};
use tracing_subscriber::{EnvFilter, util::SubscriberInitExt};

const ETC_FIREZONE_GATEWAY_TOKEN: &str = "/etc/firezone/gateway-token";

static DRY_RUN: LazyLock<bool> = LazyLock::new(|| {
    std::env::var("FZ_DRY_RUN")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or_default()
});

fn main() -> Result<()> {
    let _guard = tracing_subscriber::fmt()
        .without_time()
        .with_target(false)
        .with_env_filter(EnvFilter::from_default_env())
        .with_writer(std::io::stdout)
        .set_default();

    let cli = Cli::parse();

    use Component::*;
    use GatewayCommand::*;

    match cli.component {
        Gateway(Authenticate { replace }) => {
            anyhow::ensure!(cfg!(target_os = "linux"), "Only supported Linux right now");
            anyhow::ensure!(is_root(), "Must be executed as root");

            if let Ok(existing) = std::fs::read_to_string(ETC_FIREZONE_GATEWAY_TOKEN)
                && !existing.trim().is_empty()
                && !replace
            {
                anyhow::bail!(
                    "Found existing token at {ETC_FIREZONE_GATEWAY_TOKEN}, use --replace to overwrite"
                );
            }

            let token = loop {
                println!("Paste the token from the portal's deploy page:");

                let token =
                    rpassword::read_password().context("Failed to read token from stdin")?;

                if token.trim().is_empty() {
                    continue;
                }

                break SecretString::new(token.into_boxed_str());
            };

            write_to_file(ETC_FIREZONE_GATEWAY_TOKEN, token)?;

            println!("Successfully installed token");
            println!("Tip: You can now start the Gateway with `firezone gateway enable-service`");
        }
        Gateway(EnableService) => {
            anyhow::ensure!(cfg!(target_os = "linux"), "Only supported Linux right now");
            anyhow::ensure!(is_root(), "Must be executed as root");

            run("systemctl", "enable --now firezone-gateway.service")
                .context("Failed to enable `firezone-gateway.service`")?;

            println!("Successfully enabled `firezone-gateway.service`");
        }
        Gateway(DisableService) => {
            anyhow::ensure!(cfg!(target_os = "linux"), "Only supported Linux right now");
            anyhow::ensure!(is_root(), "Must be executed as root");

            run("systemctl", "disable firezone-gateway.service")
                .context("Failed to disable `firezone-gateway.service`")?;

            println!("Successfully disabled `firezone-gateway.service`");
        }
    }

    Ok(())
}

#[derive(Parser, Debug)]
#[command(name = "firezone", bin_name = "firezone", about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    component: Component,
}

#[derive(Debug, Subcommand)]
enum Component {
    #[command(subcommand)]
    Gateway(GatewayCommand),
}

#[derive(Debug, Subcommand)]
enum GatewayCommand {
    /// Securely store the Gateway's token on disk.
    Authenticate {
        /// If an existing token is found, replace it.
        #[arg(long, default_value_t = false)]
        replace: bool,
    },
    /// Enable the Gateway's systemd service.
    EnableService,
    /// Disable the Gateway's systemd service.
    DisableService,
}

#[cfg(target_os = "linux")]
fn is_root() -> bool {
    if *DRY_RUN {
        return true;
    }

    nix::unistd::Uid::current().is_root()
}

#[cfg(not(target_os = "linux"))]
fn is_root() -> bool {
    true
}

fn write_to_file(path: &str, content: SecretString) -> Result<()> {
    tracing::debug!("Writing {} bytes to {path}", content.expose_secret().len());

    check_dry_run()?;

    std::fs::write(path, content.expose_secret())
        .with_context(|| format!("Failed to write to `{path}`"))?;

    Ok(())
}

fn run(bin: &str, args: &str) -> Result<()> {
    tracing::debug!("Running `{bin} {args}`");

    check_dry_run()?;

    let output = Command::new(bin)
        .args(args.split_ascii_whitespace())
        .output()?;

    anyhow::ensure!(
        output.status.success(),
        "`{bin} {args}` exited with {}",
        output.status
    );

    Ok(())
}

fn check_dry_run() -> Result<()> {
    anyhow::ensure!(!*DRY_RUN, "Aborting because `FZ_DRY_RUN=true`");

    Ok(())
}
