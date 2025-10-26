#![expect(clippy::print_stdout, reason = "We are a CLI.")]

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use secrecy::SecretString;

const ETC_FIREZONE_GATEWAY_TOKEN: &str = "/etc/firezone/gateway-token";

fn main() -> Result<()> {
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

                break SecretString::new(token);
            };

            install_firezone_gateway_token(token)?;

            println!("Successfully installed token");
            println!("Tip: You can now start the Gateway with `firezone gateway enable`");
        }
        Gateway(Enable) => {
            anyhow::ensure!(cfg!(target_os = "linux"), "Only supported Linux right now");
            anyhow::ensure!(is_root(), "Must be executed as root");

            enable_gateway_service().context("Failed to enable `firezone-gateway.service`")?;

            println!("Successfully enabled `firezone-gateway.service`");
        }
        Gateway(Disable) => {
            anyhow::ensure!(cfg!(target_os = "linux"), "Only supported Linux right now");
            anyhow::ensure!(is_root(), "Must be executed as root");

            disable_gateway_service().context("Failed to disable `firezone-gateway.service`")?;

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
    Enable,
    /// Disable the Gateway's systemd service.
    Disable,
}

#[cfg(target_os = "linux")]
fn is_root() -> bool {
    nix::unistd::Uid::current().is_root()
}

#[cfg(not(target_os = "linux"))]
fn is_root() -> bool {
    true
}

#[cfg(target_os = "linux")]
fn install_firezone_gateway_token(token: SecretString) -> Result<()> {
    use secrecy::ExposeSecret;

    std::fs::write(ETC_FIREZONE_GATEWAY_TOKEN, token.expose_secret())
        .with_context(|| format!("Failed to write token to `{ETC_FIREZONE_GATEWAY_TOKEN}`"))?;

    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn install_firezone_gateway_token(token: String) -> Result<()> {
    anyhow::bail!("Not implemented")
}

#[cfg(target_os = "linux")]
fn enable_gateway_service() -> Result<()> {
    use std::process::Command;

    let output = Command::new("systemctl")
        .arg("enable")
        .arg("--now")
        .arg("firezone-gateway.service")
        .output()?;

    anyhow::ensure!(
        output.status.success(),
        "`systemctl enable` exited with {}",
        output.status
    );

    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn enable_gateway_service() -> Result<()> {
    anyhow::bail!("Not implemented")
}

#[cfg(target_os = "linux")]
fn disable_gateway_service() -> Result<()> {
    use std::process::Command;

    let output = Command::new("systemctl")
        .arg("disable")
        .arg("firezone-gateway.service")
        .output()?;

    anyhow::ensure!(
        output.status.success(),
        "`systemctl disable` exited with {}",
        output.status
    );

    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn disable_gateway_service() -> Result<()> {
    anyhow::bail!("Not implemented")
}
