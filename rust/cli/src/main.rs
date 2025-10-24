#![expect(clippy::print_stdout, reason = "We are a CLI.")]

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

fn main() -> Result<()> {
    let cli = Cli::parse();

    use Component::*;
    use GatewayCommand::*;

    match cli.component {
        Gateway(Authenticate) => {
            anyhow::ensure!(cfg!(target_os = "linux"), "Only supported Linux right now");
            anyhow::ensure!(is_root(), "Must be executed as root");

            let mut token = String::with_capacity(512); // Our tokens are ~270 characters, grab the next power of 2.

            loop {
                println!("Paste the token from the portal's deploy page:");

                let num_bytes = std::io::stdin()
                    .read_line(&mut token)
                    .context("Failed to read token from stdin")?;

                if num_bytes == 0 || token.trim().is_empty() {
                    continue;
                }

                break;
            }

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
    Authenticate,
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
fn install_firezone_gateway_token(token: String) -> Result<()> {
    std::fs::write("/etc/firezone/gateway-token", token)
        .context("Failed to write token to `/etc/firezone/gateway-token`")?;

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
